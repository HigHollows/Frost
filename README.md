# FROST

**A minimalist Arch Linux distribution for full-stack developers.**

FROST strips Arch down to a clean, reproducible base and layers on exactly what a full-stack dev needs to be productive on day one — a container runtime, a modern editor, a JS/Python toolchain, sane shell defaults — without dragging in a heavyweight desktop environment or opinionated bloat you'll spend an afternoon ripping out.

No installer GUI, no hidden magic: FROST is three readable, commented, failsafe bash scripts. You can read every line before you run it as root.

```
 ███████╗██████╗  ██████╗ ███████╗████████╗
 ██╔════╝██╔══██╗██╔═══██╗██╔════╝╚══██╔══╝
 █████╗  ██████╔╝██║   ██║███████╗   ██║
 ██╔══╝  ██╔══██╗██║   ██║╚════██║   ██║
 ██║     ██║  ██║╚██████╔╝███████║   ██║
 ╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝
        minimalist Arch for full-stack devs
```

## Status

✅ **Validated end-to-end.** All three phases have been run back-to-back in a clean VirtualBox VM (UEFI, fresh disk) from Arch ISO boot through to a working, logged-in system: `pacstrap` bootstrap → AUR helper build → user/bootloader/profile setup → **successful reboot to a `frost login:` prompt**, with `sudo`, `docker`, and `sshd` all confirmed active. See [ARCHITECTURE.md](ARCHITECTURE.md#validation-history) for the bugs that testing surfaced and how they were fixed.

## What you get

| Layer | Details |
|---|---|
| Base | `base`, `linux`, `linux-firmware`, `mkinitcpio`, `sudo`, `networkmanager` |
| Dev toolchain | git, neovim, tmux, htop, curl/wget, Python 3 + pip, Node.js + npm, Docker + Compose |
| Package management | pacman tuned (color, parallel downloads, multilib) + a trusted AUR helper (`yay` or `paru`), built by a throwaway unprivileged user — never as root |
| Shell experience | idempotent default dotfiles (bash aliases, tmux, git, neovim) applied via a managed block, safe to re-run |
| System identity | hostname, locale, timezone, fstab, bootloader (`systemd-boot` on UEFI, `grub` on BIOS) — auto-detected |
| Accounts | a real sudo-capable user, password entered interactively (never as a CLI arg, never logged) |
| Profiles (optional) | `desktop` (Xorg + i3 + lightdm + pipewire) or `server` (openssh + ufw + fail2ban) |
| Distribution | a generated `archiso` profile so FROST can ship as a bootable live ISO — the ISO even carries its own install scripts, so it can install itself |
| `frost-cli` | `frost status` / `doctor` / `update` — a tiny helper installed to `/opt/frost/bin/`, symlinked onto `PATH` |

## Quick start

Run as root, either from the Arch live ISO (bootstrap mode — installs to a disk you've already partitioned and mounted) or on an already-installed Arch system (local mode, auto-detected):

```bash
# 1. Foundations: base system + dev toolchain + /opt/frost/
sudo ./frost-build.sh --target /mnt

# 2. AUR helper + dotfiles + frost-cli
sudo ./frost-phase2.sh --target /mnt

# 3. Hostname/locale/bootloader + user account + optional profile + ISO packaging
sudo ./frost-phase3.sh --target /mnt --username yourname --profile server
```

Every script supports `--dry-run` (see what would happen, change nothing) and fails safe: on error, changes made *by that run* are rolled back automatically (config backups restored, partial files removed, thrown-away build users deleted).

Full flag reference and design notes for each phase:

- [frost-build.README.md](frost-build.README.md) — Phase 1: Foundations
- [frost-phase2.README.md](frost-phase2.README.md) — Phase 2: AUR helper, dotfiles, frost-cli
- [frost-phase3.README.md](frost-phase3.README.md) — Phase 3: users, profiles, ISO packaging

## Requirements

- An Arch Linux live ISO (for a fresh install) or an existing Arch system (for local provisioning)
- Root access
- A network connection
- For Phase 3's bootloader step: your target disk already partitioned, formatted, and mounted (including the ESP for UEFI) — FROST deliberately never partitions a disk for you

## Project layout

```
frost-build.sh              Phase 1 script
frost-phase2.sh              Phase 2 script
frost-phase3.sh              Phase 3 script
frost-build.README.md         Phase 1 docs
frost-phase2.README.md        Phase 2 docs
frost-phase3.README.md        Phase 3 docs
ARCHITECTURE.md                Design notes, safety model, lessons from real testing
ROADMAP.md                      Where FROST is headed
CONTRIBUTING.md                  Commit convention, code conventions
LICENSE                          MIT
```

`/opt/frost/` is the runtime footprint FROST leaves on an installed system: `bin/` (frost-cli), `config/`, `scripts/`, `cache/`, `logs/`, `state/` (phase completion markers).

## Design principles

1. **Read before you run.** No compiled installer binary, no download-and-pipe-to-bash. Every step is a commented bash function.
2. **Fail safe, not silent.** `set -euo pipefail` + `trap ERR` everywhere; every destructive step is preceded by a backup, and rollback undoes only what that specific run created.
3. **Least privilege by default.** AUR packages are never built as root — a throwaway user does it, with `sudo` scoped to exactly `pacman`, deleted after.
4. **No surprise credentials.** Passwords are always prompted interactively and piped to `chpasswd` via stdin — never a CLI argument, never a log line.
5. **Minimal means minimal.** No AUR packages baked into the base image or the live ISO — only official-repo packages. AUR (and anything not in core/extra) stays an explicit, visible post-install step.

More on the reasoning behind these in [ARCHITECTURE.md](ARCHITECTURE.md).

## License

MIT — see [LICENSE](LICENSE).
