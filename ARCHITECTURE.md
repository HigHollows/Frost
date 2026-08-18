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

### Lesson 5: `/var/log/frost` needs to be writable by more than root

Found running `frost-status` as the regular sudo user right after a full `frost-deploy.sh` run: `Permission denied` writing `/var/log/frost/status.log.tmp`.

`frost-deploy.sh` creates `/var/log/frost/` (for `frost.log`, `deploy-checkpoint.state`, `status.log`, `security-audit.log`) as root, with the default `mkdir -p` mode — effectively `0755` owned by `root:root`. That's fine for `frost-daemon.service` (runs as root) but locks out the exact use case `frost-status` is meant for: a regular admin user checking system health without needing `sudo` for something that isn't sensitive.

**Fix:** `/var/log/frost` is created `1777` (world-writable, sticky bit — the same shape as `/tmp`) by `frost-deploy.sh` at setup time, plus a best-effort self-heal `chmod` in `frost-common.sh`'s `_frost_log_line()` in case anything ever writes there before deploy sets it up. None of the files in that directory are sensitive (status/log data, not secrets), so world-writable is an acceptable trade for "both root services and interactive users can use it without friction."

### Lesson 6: `dconf load` uses GKeyFile parsing — `;` comments are silently fatal

Found investigating why `frost-desktop.sh`'s theme/wallpaper/extensions never visibly applied after a real GNOME login, even though the install itself reported success. `apply_dconf_defaults()` ships `desktop/config/dconf-frost-defaults.ini` and loads it with `dconf load / < file`. That file used `;` as its comment leader (a natural choice — it's the traditional INI-family comment character, and looks harmless next to the `[section]`/`key=value` lines). But `dconf load` parses with GLib's `GKeyFile`, which only recognizes `#` as a comment prefix; a `;` line is a hard parse error (`Key file contains line "..." which is not a key-value pair, group, or comment`), and `dconf load` aborts the *entire* load — none of the keys are applied, not just the ones near the bad line.

The failure was real on every run (confirmed by reproducing it manually over SSH), but invisible in normal use: `apply_dconf_defaults()` wraps the load in `run ... || warn "dconf load failed — apply manually: ..."`, so the script printed a warning and moved on — easy to miss in a long chained `frost-deploy.sh` run, and the specific log line that would have shown it was gone by the time this was investigated (rotated out during disk-space cleanup, see below).

**Fix:** `desktop/config/dconf-frost-defaults.ini`'s comments changed from `;` to `#` throughout. Verified by re-running `dconf load` against the fixed file on the live test VM — it now exits 0, and `gsettings get`/a live screenshot confirmed the FROST wallpaper, `FROST` GTK theme, and all three GNOME Shell extensions (`frost-shell@frost-os`, Dash to Dock, Blur my Shell) actually apply and render. Any future dconf/keyfile-format asset in this repo should use `#`, never `;`.

### Lesson 7: two real bugs kept `frost-shell@frost-os` from ever actually running

Found while adding the signature-identity visual pass (hex accents, a custom panel icon) — a good excuse to finally load the extension into a real GNOME session instead of just syntax-checking it. It had never actually run before. Two separate, real bugs, both silent (GNOME degrades a broken extension to "not running" rather than crashing the session):

1. **`shell-version` was stale.** `metadata.json` only listed `["45", "46", "47"]`; the test VM runs GNOME Shell 50.4. GNOME Shell refuses to load an extension outside its declared range — `gnome-extensions info` reports `State: OUT OF DATE`, `Enabled: Yes` in dconf notwithstanding. **Fix:** extended the list through `"50"` (and a couple ahead, `"48"`/`"49"`, since bumping this every point release isn't sustainable either).

2. **`metadata.json` was missing `settings-schema`.** `enable()` calls `this.getSettings()` with no arguments, which only works if `metadata.json` declares which schema id that resolves to. Without it: `Error: Expected type string for argument 'schema_id' but got type undefined` at `getSettings()`, extension state `ERROR`. **Fix:** added `"settings-schema": "org.gnome.shell.extensions.frost-shell"`, matching the `id` already declared in `schemas/org.gnome.shell.extensions.frost-shell.gschema.xml`.

A third bug surfaced once the extension could actually reach its own code: `Main.panel.statusArea.quickSettings.addExternalIndicator(this._steamToggle)` was passed a bare `QuickSettings.QuickToggle` instance. The real GNOME 45+ contract for `addExternalIndicator()` is a `QuickSettings.SystemIndicator` wrapper — it reads a `quickSettingsItems` array off the object it's given, which a raw toggle doesn't have. Passing the toggle directly threw `TypeError: can't access property "forEach", items is undefined` deep inside `panel.js`. **Fix:** wrapped the toggle in a small `SystemIndicator` subclass (`SteamModeIndicator`) that pushes the toggle into its own `quickSettingsItems`, matching the pattern in GNOME's own extension-writing guide.

All three were invisible from the outside in exactly the same way: `gnome-extensions list --enabled` still lists the extension (that's just the dconf toggle), so nothing *looks* broken unless you check `gnome-extensions info <uuid>`'s `State:` field or `journalctl --user -b | grep <uuid>` on a live session — syntax-checking a `.js` file with Node, as this repo had been doing, catches none of this, because all three are runtime API-contract mismatches, not syntax errors.

**Also learned mid-fix:** `gnome-extensions disable && enable` in the same shell session doesn't reliably clear an extension out of an `ERROR` state once it's thrown once — a full logout/login (fresh `gnome-shell` process) was needed to get a clean re-evaluation after each fix, three separate times, before `State: ACTIVE` and a working Steam Mode toggle/FROST menu were confirmed.

### Lesson 8: neither the GDM logo nor the garbled login-screen text came from where it looked like they would

Found while polishing the desktop experience — the login screen showed the stock Arch Linux logo and, after entering a password, a wall of garbled `[1;36m` escape-code text. Both looked like they should be simple to fix and neither was where expected:

**The garbled text** wasn't `/etc/motd` being malformed — it's a real, colorful, correctly-rendering banner over SSH/tty. The problem is that GDM's greeter surfaces PAM session text messages **raw**, with zero ANSI interpretation, and `gdm-password`/`gdm-autologin`'s PAM session stack chains through `system-local-login` → `system-login`, which includes `pam_motd.so` — a directive meant for real shell logins, inherited by the graphical greeter along the way. Stripping ANSI from `/etc/motd` would have "fixed" GDM at the cost of making the actual SSH/tty experience worse. **Fix:** `frost-desktop.sh`'s `disable_motd_on_gdm()` replaces the `session include system-local-login` line in those two PAM files with the same stack expanded inline, minus `pam_motd.so`/`pam_mail.so` — auth/account/password untouched, `/etc/motd` untouched.

**The Arch logo** wasn't coming from `/etc/os-release`'s `LOGO=` field at all, despite that being the documented freedesktop mechanism GNOME is supposed to read — clearing it (and even fully rewriting `/etc/os-release` with FROST's own identity) had zero visible effect, even after restarting `gdm.service`. The actual source: Arch's `gdm` package ships `/usr/share/glib-2.0/schemas/30_org.archlinux.gdm.gschema.override`, which hardcodes `org.gnome.login-screen`'s `logo` key directly to `/usr/share/pixmaps/archlinux-logo-text-dark.svg` — a compiled gschema *default* override, not a runtime-configurable value `os-release` can influence. **Fix:** `remove_gdm_arch_logo()` writes `/usr/share/glib-2.0/schemas/50_frost.gschema.override` (sorts after `30_`, so its `logo=""` wins after `glib-compile-schemas` recompiles) and restarts `gdm.service`. Confirmed via screenshot — logo gone, no FROST logo substituted in its place, matching what was actually asked for.

**Also learned:** GNOME's own About panel (`gnome-control-center` → System → About) only ever renders `PRETTY_NAME` from `os-release` — setting `ID_LIKE=arch` (the correct freedesktop field for "this distro derives from Arch") is real and read by `hostnamectl`/scripting tools, but doesn't surface as a visible "based on Arch Linux" line in that GUI panel. Not a bug to fix — just a GNOME limitation worth knowing about before promising a specific UI location for a credit line.

### Real disk space needed is well past the per-pack estimates

Each pack's own README estimated its *individual* footprint (5GB here, 10GB there) — accurate in isolation, but a full `frost-deploy.sh` run (core + branding + security + gaming) followed by `frost-desktop.sh` (GNOME) on the same 20GB test disk hit **0 bytes free**, mid-deployment. Steam's multilib dependency tree, a JDK for Burpsuite, a full GNOME Shell stack, and several AUR source builds all add up faster than each pack's standalone estimate suggests. **Budget 40GB+ for a disk that will run the full stack**, not the 15-20GB the per-pack docs suggest in isolation — those numbers are still correct for running *that one pack alone*, just not additive across all of them plus the desktop.

## Why not just use `archinstall`?

`archinstall` is a fine general-purpose interactive installer. FROST is narrower and more opinionated on purpose: a fixed, reviewable package set for one audience (full-stack devs), scriptable end-to-end with no TUI to click through, and structured as three composable phases so you can stop after Phase 1 (just the base + toolchain) or Phase 2 (add AUR/dotfiles) without committing to the full user/bootloader/ISO pipeline.
