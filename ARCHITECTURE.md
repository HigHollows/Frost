# FROST — Architecture & design notes

This document explains *how* FROST's three build scripts work internally, the safety mechanisms shared across them, and the real bugs that surfaced during VM validation — kept here so nobody reintroduces them.

## The two build modes

Every FROST script auto-detects which of two modes it's running in:

- **bootstrap** — running from the Arch live ISO, `pacstrap` is available, and `--target` (default `/mnt`) is an already-mounted filesystem. The script installs *into* that target via `pacstrap`/`arch-chroot`, never touching the live environment's own running system.
- **local** — running on an already-installed Arch system (or forced via `--local`). The script provisions the machine it's actually running on, directly via `pacman`.

This split exists so the same scripts can build a fresh disk image from the live ISO *and* be used to test/iterate against an already-running Arch box (a VM, a container, a dev machine) without maintaining two codepaths.

```
                 ┌─────────────────────┐
 Arch live ISO → │ frost-build.sh       │ → pacstrap → /mnt (bootstrap mode)
                 │ frost-phase2.sh      │ → arch-chroot /mnt ...
                 │ frost-phase3.sh      │
                 └─────────────────────┘

 Installed Arch → │ same scripts, --local │ → pacman directly on the host
```

### `chroot_exec` — the key abstraction

Phases 2 and 3 funnel every command that needs to run "inside the target" through one helper:

```bash
chroot_exec() {
    if [[ "$BUILD_MODE" == "bootstrap" ]]; then
        arch-chroot "$FROST_TARGET" bash -c "$1"
    else
        bash -c "$1"
    fi
}
```

It takes a **single shell-command string**, not an argv array. That's a deliberate trade-off — it lets one line describe "run this pipeline inside the target regardless of mode" — but it has a sharp edge (see [Lesson 2](#lesson-2-arr-joins-silently-break-inside-a-chroot_exec-string) below).

## Safety model

Shared across all three scripts:

| Mechanism | What it does |
|---|---|
| `set -euo pipefail` | Any unhandled command failure stops the script immediately instead of limping on |
| `trap rollback ERR` | On failure, undoes *only what that run created* — restores config backups (`pacman.conf`, `sudoers`, `fstab`, `locale.gen`), deletes files/dirs it created (scoped to `/opt/frost/*` and the target path, never anything else), removes throwaway users |
| Config backups before edit | `pacman.conf`, `sudoers`, `fstab`, `locale.gen` are always copied to a timestamped `.frost-bak-<ts>` before modification |
| `visudo -c` validation | The sudoers wheel-group edit is syntax-checked before being accepted; an invalid result is reverted immediately, never left in place |
| Regex-allowlisted inputs | `--username`, `--hostname`, `--locale`, `--timezone`, `--bootloader`, `--profile` are validated against strict patterns before being interpolated into `chroot_exec` command strings — defense in depth against injection |
| Passwords never touch argv or logs | Read interactively (`read -s`), piped to `chpasswd` over stdin. A non-interactive shell gets a **locked** account, never a default/weak password |
| Least-privilege AUR builds | A throwaway `frostbuilder` user builds AUR packages; its `sudo` grant is scoped to exactly `/usr/bin/pacman`, and both the user and the sudoers drop-in are deleted after (success or failure) |
| `--dry-run` everywhere | Every state-changing call is routed through a `run()` wrapper that no-ops and prints instead of executing |

## Package philosophy

- The **base system and live ISO** only ever pull from official repos (`core`/`extra`, `multilib` on x86_64). Nothing from the AUR is baked into an image.
- The **AUR helper itself** (`yay-bin`/`paru-bin`) is the one AUR exception, and it's built transparently by a throwaway unprivileged user, not silently.
- **VSCode** specifically is *never* auto-installed — it's AUR-only (`visual-studio-code-bin`), and FROST just logs the exact `yay -S`/`paru -S` command rather than assume a trusted AUR helper exists yet.

This keeps the trust boundary obvious: anything that ends up on a FROST system either came from Arch's signed official repos, or was an AUR build you can see happening.

## Validation history

FROST was tested by actually running all three phases in a fresh VirtualBox VM (UEFI firmware, blank 20GB disk) from Arch ISO boot through to a real reboot. Three real bugs were found this way — documented here so they don't come back:

### Lesson 1: `pacstrap` needs an unambiguous package list, not just `--noconfirm`

Recent pacman treats the initramfs generator as a virtual package with multiple providers (`mkinitcpio`/`booster`/`dracut`) and will interactively ask which one to use if none is named explicitly — this blocks a supposedly non-interactive bootstrap dead in its tracks.

**Fix:** `frost-build.sh` lists `mkinitcpio` explicitly in `base_pkgs`, removing the ambiguity entirely. No prompt, no dependency on stray buffered keystrokes to "accidentally" answer it.

### Lesson 2: array joins silently break inside a `chroot_exec` string

All three scripts set `IFS=$'\n\t'` at the top (a common bash-safety idiom — it stops word-splitting on spaces in filenames). But `"${array[*]}"` joins on the **first character of `$IFS`**, not a space. With `IFS` starting with `\n`, `${pkgs[*]}` silently produces a *newline-separated* string.

That's invisible almost everywhere — except when it gets embedded into a `chroot_exec "pacman -S ... ${pkgs[*]}"` string, which is then run as `bash -c "$1"`. A newline inside that string turns one `pacman -S pkg1 pkg2 pkg3` call into **three separate commands**: `pacman -S pkg1`, then `pkg2` and `pkg3` run as bare (nonexistent) commands. In practice: only the first package installed, and the rest failed with `command not found` — silently, since the failure looked like an unrelated shell error, not a pacman error.

**Fix:** `frost-phase3.sh`'s profile installer builds its package lists as plain space-separated strings instead of arrays, sidestepping the `IFS`-join trap entirely. If you add a new `chroot_exec`-based package install anywhere in these scripts, do the same — never `"${arr[*]}"` (or `"${arr[@]}"` embedded mid-string) into a `chroot_exec` argument.

### Lesson 3: the live ISO's own package database is per-boot, not persistent

`generate_iso_profile()` installs `archiso` on the **host** (the live-boot environment itself, not the chroot target) to build the ISO profile. The target's package databases are synced once by Phase 1 and persist to disk — but the live ISO's own databases are reset on every fresh boot and stay empty until something runs `pacman -Sy`.

If Phase 3 runs in a session where nothing else already synced the live environment's databases, `pacman -S archiso` fails with `target not found`, even though the package obviously exists.

**Fix:** `generate_iso_profile()` runs `pacman -Sy --noconfirm` on the host immediately before installing `archiso`, independent of whatever state the target's databases are in.

### Lesson 4: a bare `[[ cond ]] && { ...; exit 1; }` as a whole function body inverts under `set -e`

Found testing `frost-deploy.sh` chaining into `frost-branding.sh` for the first time (a later VM session than the Phase 1-3 pass above) — the script died silently right after `check_root`, no error message, even though it *was* running as root.

`check_root() { [[ "$EUID" -ne 0 ]] && { error ...; exit 1; }; }` looks like a harmless one-liner, and the equivalent bare `[[ cond ]] && action` statement written *directly* in a function body (not isolated as the function's entire content) is genuinely safe under `set -e` — bash exempts a command that's "part of a list controlled by `&&`/`||`" from triggering `-e`, and this is a common, correct idiom used throughout FROST (e.g. every `rollback()`'s `[[ -z "$pair" ]] && continue`).

The trap: when that guard is a function's **entire** body, and the condition is false (the good path — you *are* root), the guard's own exit status (1, from the failed left-hand test) becomes the function's return value. At the call site (`check_root`, called bare in `main()`), that's just an ordinary command returning non-zero — the `&&` exemption is local to where the `&&` textually appears and does **not** propagate across a function-call boundary. `set -e` sees a plain command fail and aborts, on the path where everything was actually fine.

Confirmed with a 5-line reproduction before trusting the diagnosis (see the commit history) — a function whose entire body is `[[ 1 -eq 2 ]] && { echo hi; }`, called bare, kills a `set -e` script on the spot; the same guard written as one statement among several in a larger function does not.

**Fix:** never write a validation guard as a function's sole statement in `&&` form. Use `if`/`fi` instead — `if [[ cond ]]; then action; fi` returns 0 regardless of whether the branch ran, so it can't invert a function's return value this way. `frost-branding.sh` and `frost-gaming.sh`'s `check_root()` were rewritten this way (matching what `frost-build.sh`/`frost-phase2.sh`/`frost-phase3.sh` already did — this bug was specific to the later scripts that had compacted the idiom for brevity).

## Why not just use `archinstall`?

`archinstall` is a fine general-purpose interactive installer. FROST is narrower and more opinionated on purpose: a fixed, reviewable package set for one audience (full-stack devs), scriptable end-to-end with no TUI to click through, and structured as three composable phases so you can stop after Phase 1 (just the base + toolchain) or Phase 2 (add AUR/dotfiles) without committing to the full user/bootloader/ISO pipeline.
