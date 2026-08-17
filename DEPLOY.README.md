# FROST — Deployment & Auto-Update pack

The operations layer: one command to deploy all of FROST end-to-end, a config-driven update system, background health monitoring, and a clean uninstall path. Sits on top of everything else in this repo — [ARCHITECTURE.md](ARCHITECTURE.md) is still the reference for how the individual scripts this orchestrates actually work.

## `frost-deploy.sh` — the orchestrator

```bash
sudo ./frost-deploy.sh --target /mnt --username you --profile server
sudo ./frost-deploy.sh --local --skip-branding --skip-gaming
sudo ./frost-deploy.sh --target /mnt --dry-run
```

Chains, in order: `frost-build.sh` → `frost-phase2.sh` → `frost-phase3.sh` → `frost-branding.sh` → `frost-security.sh` → `frost-gaming.sh` → installs the operations layer itself (`/etc/frost/frost.conf`, `/opt/frost/lib/`, `frost-update`/`frost-status`/`frost-uninstall`, four systemd units). The three optional packs are skippable: `--skip-branding`, `--skip-security`, `--skip-gaming`.

**Note on numbering:** this repo's actual phase numbers are Phase 1 (`frost-build.sh`), Phase 2 (`frost-phase2.sh`), Phase 3 (`frost-phase3.sh`) — the "core" pipeline. Branding, security, and gaming are separate *optional packs*, not literally "Phase 4/5/6" in the code (each was requested and named independently). `frost-deploy.sh` chains all six regardless of how you think about the numbering.

### Pre-flight checks

Before touching anything: root, Arch Linux, all script files present, free disk space (warns under 10GB, asks to confirm), network reachability (`archlinux.org`), and — in bootstrap mode — whether the target already has non-FROST content on it (asks before pacstrapping over something that isn't empty and wasn't already a FROST Phase 1 install).

### What "rollback" actually means here

Each of the six scripts already has its own `trap ERR` rollback that undoes exactly what *that run* changed (config backups restored, partial files removed — see `ARCHITECTURE.md`). `frost-deploy.sh` does **not** additionally try to undo *earlier, already-successful* phases when a *later* one fails. Unwinding a working pacstrap + bootloader + user setup because, say, `frost-gaming.sh` failed to install Steam would be far riskier than just stopping and telling you exactly where it stopped. That's the design:

```
❌ CRITICAL: Boot & Aesthetic pack failed. Rollback initiated...

Deployment stopped at: Boot & Aesthetic pack
Phases completed successfully before this (still in place, not rolled back):
  phase1=ok
  phase2=ok
  phase3=ok

Boot & Aesthetic pack's own internal rollback already reverted whatever IT
partially changed — see its log under /tmp/frost-*.log for details. Fix the
underlying issue, then:
  sudo ./frost-deploy.sh --target /mnt --resume
```

### Checkpoints & `--resume`

Every phase's outcome (`running`/`ok`/`failed`) is written to `/var/log/frost/deploy-checkpoint.state`. `--resume` skips any phase already checkpointed `ok`, so after fixing whatever broke you re-run the exact same command with `--resume` appended rather than starting over. `frost-status.sh` reads this same file to show deploy history.

### Progress display

```
[████████████░░░░░░░░]  57% (4/7) ❄️  Boot & Aesthetic pack
```

### Interactive confirmations

Pre-flight and a couple of deploy-level decision points use:

```
⚠️  WARNING: <issue>. Continue? (y/n)
```

With a tty attached, it actually asks. Without one (or under a systemd service — no tty either way), it **defaults to "no"** rather than guessing — pass `--yes` to auto-confirm for scripted/unattended runs. This is the same fail-safe-not-silent posture as the rest of FROST: an automated run that hits a warning nobody can see should stop, not plow through it.

## `frost-update.sh` — updates, safely opt-in

```bash
frost-update       # check only (symlinked to /usr/local/bin by frost-deploy.sh)
frost-update --apply           # check, confirm, then actually update
frost-update --apply --yes        # same, unattended
```

Checks official packages (via `checkupdates` from `pacman-contrib` — doesn't touch the live package DB just to check) and AUR packages (via whichever helper Phase 2 installed, run as the non-root target user, never root), prints a colored per-package changelog (`name  old-ver -> new-ver`), and **only ever applies anything if told to** — `--apply`, or `FROST_AUTO_APPLY_UPDATES=true` in `frost.conf` (default `false`). The weekly timer runs in check-only mode unless you've explicitly flipped that setting — an unattended `pacman -Syu` with nobody watching is a real risk on any machine you actually use, so it's opt-in, not the default.

## Systemd services

| Unit | Schedule | What it does |
|---|---|---|
| `frost-daemon.service` | continuous | `frost-status.sh --watch 300` in a loop — the background health monitor |
| `frost-security.timer` → `frost-security.service` | daily | `frost-security-audit.sh` — **local-only** posture check (firewall, fail2ban, listening ports, pending updates, SSH hardening state). Never scans or contacts anything else — see below |
| `frost-update.timer` → `frost-update.service` | weekly | `frost-update.sh --from-timer` — check (and apply only if opted in) |
| `frost-performance.timer` → `frost-performance.service` | hourly | `paccache` trim, journal vacuum (7d), `docker system prune` — all cheap/idempotent, a leading `-` on each so a missing tool doesn't fail the unit |

```bash
systemctl status frost-daemon.service
systemctl status 'frost-*'                 # everything at once
systemctl list-timers 'frost-*'                # next-run schedule
journalctl -u frost-update.service              # a specific run's output
```

### Why the security timer never scans anything external

`frost-security.sh` (a *different* script — the pentest **tools installer**) puts nmap/hydra/sqlmap/etc. on your system for *you* to point deliberately, with authorization, at something you're allowed to test. An unattended daily timer has no mechanism to verify authorization for an external target — so `frost-security-audit.sh` (installed by *this* pack) is scoped, permanently, to auditing the local machine's own security posture only: is the firewall active, is fail2ban running, what's listening, are there pending updates, is SSH hardened. If you want to actually run scans against something, do it yourself with the real tools — never something a timer decided to do on your behalf.

## `/etc/frost/frost.conf`

```bash
FROST_VERSION="2.0"
FROST_COMPONENTS="core"              # kept in sync by frost-deploy.sh
FROST_TARGET_USER=""                    # your sudo user — AUR delegation, notifications
FROST_AUTO_APPLY_UPDATES="false"           # see frost-update.sh above
FROST_UPDATE_CHECK_AUR="true"
FROST_PERFORMANCE_MODE="balanced"             # informational, mirrors `frost --mode`
```

Validated as plain bash (`bash -n`) before ever being sourced — a syntax error in it is logged and the built-in defaults are used instead of sourcing something broken. `frost-status.sh` reports its validity every run.

## `frost-status.sh` — health check & monitor

```bash
frost-status                # one-shot report, exit 0 (healthy) / 1 (issues found)
frost-status --watch 300       # loop forever — this is what frost-daemon.service runs
```

Reports: installed packs, deploy checkpoints, config validity, all four systemd units' state, firewall, Docker, disk space, pending updates, system + FROST uptime. Writes `/var/log/frost/status.log` every run and sends a desktop notification (best-effort — see below) if it finds anything worth flagging.

### Desktop notifications from a systemd timer

`notify-send` needs a graphical session's D-Bus address, which a root-run systemd timer doesn't have by default. `notify_user()` (in `/opt/frost/lib/frost-common.sh`) finds a logged-in user via `loginctl` and posts to `unix:path=/run/user/<uid>/bus` as that user — best-effort, silently no-ops if nobody's logged in graphically or `notify-send` isn't installed. Never fails the calling script.

## `frost-uninstall.sh` — clean removal

```bash
sudo ./frost-uninstall.sh --target /mnt
sudo ./frost-uninstall.sh --local --remove-packages --yes
```

Default behavior is deliberately conservative:

1. **Backs up everything first** — one tarball (`/root/frost-uninstall-backup-<timestamp>.tar.gz`) of `/opt/frost`, `/etc/frost`, and the systemd units, before anything is touched.
2. **Removes FROST's wholly-owned files** outright (its own trees, the GRUB/Plymouth themes, the standalone config drop-ins, the systemd units) — safe, nothing else provides these.
3. **Strips FROST's managed blocks** from `.bashrc`/`.zshrc`/`/etc/zsh/zshrc` using the same markers those edits were made with.
4. **Restores the oldest `*.frost-bak-*`** for files FROST edited inline without markers (`/etc/default/grub`, `/etc/fstab`, `/etc/mkinitcpio.conf`, `/etc/pacman.conf`, `/etc/sudoers`, ...) — the earliest backup is the closest thing to "before FROST ever touched this file."

**Installed packages and user accounts are untouched unless you explicitly opt in**: `--remove-packages` removes a short, deliberately conservative list (Steam, Lutris, the security tools, GameMode, ...) — it does **not** touch anything ambiguous like Docker, PostgreSQL, git, Python, or Node.js that you may now depend on for unrelated things. `--remove-users` deletes the sudo account `frost-phase3.sh` created — off by default, asks again separately even with `--yes` at the top level, because deleting a user and their home directory is not something to do by accident.

## Quick reference

```bash
sudo ./frost-deploy.sh --target /mnt --username you    # deploy everything
frost-status                                              # health check
frost-update                                                # check for updates
frost-update --apply                                          # apply them
systemctl status 'frost-*'                                       # service states
sudo ./frost-uninstall.sh --target /mnt                             # clean removal
```
