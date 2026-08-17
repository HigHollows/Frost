# FROST — Gaming & Dev Stack pack

Gaming layer (Steam/Lutris/Heroic/GPU drivers) + full dev stack (languages/databases/IDEs) + performance tuning + a `frost --mode gaming|dev` resource-profile switch, installed on top of Phases 1-3.

## Running it

```bash
sudo ./frost-gaming.sh --target /mnt                # everything
sudo ./frost-gaming.sh --local --skip-dev              # gaming only, on an already-running box
sudo ./frost-gaming.sh --target /mnt --skip-gaming         # dev stack only
sudo ./frost-gaming.sh --target /mnt --dry-run                 # preview
```

Needs `frost-phase2.sh` (AUR helper — Heroic/VSCode/JetBrains Toolbox/MongoDB are AUR-only) and ideally `frost-phase3.sh` (a real sudo user to delegate AUR builds to). Checks free disk space up front and warns loudly (`WARN: <5GB left, cleanup required`) if there isn't much room — this pack easily installs 5-10GB.

Flags: `--username <name>`, `--aur-helper <yay|paru>`, `--skip-gaming`, `--skip-dev`, `--skip-performance`, `--skip-launcher`, `--skip-gpu-tweaks`, `--ramdisk-size <size>`, `--dry-run`. Same rollback/backup safety model as the rest of FROST.

## Gaming layer

GPU vendor is auto-detected from `lspci` (NVIDIA / AMD / Intel / VM virtual GPU) and the matching driver stack installs automatically. No GPU found at all prints `ERROR: No GPU detected 🎮` and skips driver install without aborting the rest of the script.

| Tool | Notes |
|---|---|
| **Steam** | Native `multilib` package. First launch downloads the Steam client proper; enable Proton for a game under Properties → Compatibility |
| **Lutris + Wine + Winetricks** | Lutris manages per-game Wine prefixes/runners (including DXVK/VKD3D-Proton) itself — that's deliberately not pre-configured system-wide here, it's a per-install Lutris setting |
| **Heroic Games Launcher** | AUR (`heroic-games-launcher-bin`) — Epic + GOG, same Proton/Wine backend as Steam |
| **ProtonUp-Qt** | AUR — manages custom GE-Proton / Wine-GE builds for Steam and Lutris |
| **MangoHud** | FPS/frametime/temps overlay. Enable per-game: `MANGOHUD=1 %command%` (Steam launch options) or Lutris's MangoHud toggle |
| **GameMode** | Feral's GameMode — CPU governor + I/O priority bump while a game runs. Use it: `gamemoderun %command%` (Steam) or enable in Lutris's runner options |
| **Discord, OBS Studio** | Standard chat/streaming-capture tools |

### GPU tweaks applied

NVIDIA only, and only if not already present: `nvidia-drm.modeset=1` added to the kernel command line (GRUB's `GRUB_CMDLINE_LINUX_DEFAULT` or systemd-boot's loader entry, whichever `frost-phase3.sh` installed — backed up first, idempotent). This is the standard Arch-wiki-documented setting proprietary NVIDIA needs for correct KMS/Wayland/Vulkan behavior. Skip it with `--skip-gpu-tweaks`.

AMD's `amdgpu.ppfeaturemask` (needed for manual overclocking) is deliberately **not** auto-applied — it's a real stability tradeoff you should opt into yourself if you need it, not something a script should silently flip.

## Dev stack

Languages: Python/Node.js/Docker (already from Phase 1, reinforced with `--needed`), **Rust**, **Go**, **OpenJDK**. Databases: **PostgreSQL** (frost-gaming.sh runs `initdb` for you — Arch's package deliberately doesn't do this automatically, unlike some other distros), **Redis**, **MongoDB** (AUR). IDEs: **VSCode**, **JetBrains Toolbox** (both AUR-only — same "never silently AUR-build without a helper" rule as everywhere else in FROST). Plus **GitHub CLI** (`gh`).

Package managers (pip/npm/cargo) ship with their language runtimes — nothing extra to install.

## Performance tuning

- **sysctl**: `/etc/sysctl.d/99-frost-performance.conf` — `vm.swappiness=10` (prefer RAM over swap, desktop/gaming responsiveness over the server-default 60), `vm.vfs_cache_pressure=50` (keep filesystem metadata cached longer, helps repeated-compile dev workloads).
- **RAM disk for builds**: a `tmpfs` mount at `/mnt/ramdisk-build`, auto-sized to 25% of RAM (capped 1-8GB, override with `--ramdisk-size 4G`). **Volatile by design** — point `CARGO_TARGET_DIR`, npm's cache, or `ccache` at it for a real speed boost, but never store anything there you need to survive a reboot.
- **Thermal monitoring**: `lm_sensors` with `sensors-detect --auto` (non-interactive autodetect — safe default, though less thorough than the interactive version). `fancontrol` is installed but **not configured** — its setup tool (`pwmconfig`) tests your fans one at a time interactively and needs a human watching; wrong fan curves from a blind automated guess can mean real overheating. Run it yourself:
  ```bash
  sudo pwmconfig        # interactive, follow the prompts
  sudo systemctl enable --now fancontrol
  ```

## `frost --mode gaming` / `frost --mode dev`

Wired into the existing `frost-cli` (idempotent patch — safe to re-run this script). Switches your machine's resource profile:

| | `frost --mode gaming` | `frost --mode dev` |
|---|---|---|
| Docker/PostgreSQL/Redis | stopped (free up RAM/CPU) | started |
| CPU governor | `performance` | `schedutil`/`ondemand` (balanced) |

This is a coarse, whole-system toggle — it complements GameMode (which does per-game, automatic governor switching) rather than replacing it. Use `frost --mode gaming` when you're settling in for a session and want dev services out of the way entirely; rely on GameMode for the automatic per-launch behavior otherwise.

The underlying script lives at `/opt/frost/bin/frost-mode` and works standalone even without `frost-cli` present.

## Files

```
frost-gaming.sh          the installer script
```
No config templates for this pack — its outputs are packages, service states, and the two patched files (`/etc/sysctl.d/99-frost-performance.conf`, `frost-cli`), not standalone assets like the branding/security packs.
