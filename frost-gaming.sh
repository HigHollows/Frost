#!/usr/bin/env bash
#
# frost-gaming.sh — FROST Linux, Gaming & Dev Stack pack
#
# Installs and configures the gaming layer (Steam/Lutris/Heroic, GPU
# drivers, gamemode, capture/chat tools) and the full dev stack
# (languages, databases, IDEs) on top of Phases 1-3, plus performance
# tuning and a gaming/dev resource-profile switch wired into frost-cli.
#
# Usage:
#   sudo ./frost-gaming.sh --target /mnt
#   sudo ./frost-gaming.sh --local --skip-dev
#
# See GAMING.README.md for the full tool list, performance-tuning
# rationale, and frost --mode usage.
#
# Author: FROST project
# License: MIT

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_VERSION="0.1.0-gaming"
readonly LOG_FILE="/tmp/frost-gaming-$(date +%Y%m%d-%H%M%S).log"

# ─────────────────────────────────────────────────────────────────────────
# 0. OUTPUT (same conventions as the rest of FROST)
# ─────────────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
    C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'
    C_BLUE='\033[1;34m'; C_CYAN='\033[1;36m'; C_BOLD='\033[1m'; C_RESET='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_BOLD=''; C_RESET=''
fi

log()     { printf "%b[frost]%b %s\n" "${C_CYAN}${C_BOLD}" "${C_RESET}" "$*" | tee -a "$LOG_FILE" ; }
success() { printf "%b[  ok ]%b %s\n" "${C_GREEN}${C_BOLD}" "${C_RESET}" "$*" | tee -a "$LOG_FILE" ; }
warn()    { printf "%b[ warn]%b %s\n" "${C_YELLOW}${C_BOLD}" "${C_RESET}" "$*" | tee -a "$LOG_FILE" >&2 ; }
error()   { printf "%b[FATAL]%b %s\n" "${C_RED}${C_BOLD}" "${C_RESET}" "$*" | tee -a "$LOG_FILE" >&2 ; }
step()    { printf "\n%b==>%b %b%s%b\n" "${C_BLUE}${C_BOLD}" "${C_RESET}" "${C_BOLD}" "$*" "${C_RESET}" | tee -a "$LOG_FILE" ; }

# Exact phrasing requested for this pack's status lines.
tool_missing()   { printf "%b[FATAL]%b ERROR: %s not found\n" "${C_RED}${C_BOLD}" "${C_RESET}" "$1" | tee -a "$LOG_FILE" >&2 ; }
tool_success()   { printf "%b[  ok ]%b \xE2\x9C\x85 %s installed & configured\n" "${C_GREEN}${C_BOLD}" "${C_RESET}" "$1" | tee -a "$LOG_FILE" ; }
gpu_error()      { printf "%b[FATAL]%b ERROR: No GPU detected \xF0\x9F\x8E\xAE\n" "${C_RED}${C_BOLD}" "${C_RESET}" | tee -a "$LOG_FILE" >&2 ; }
space_warn()     { printf "%b[ warn]%b WARN: <5GB left, cleanup required\n" "${C_YELLOW}${C_BOLD}" "${C_RESET}" | tee -a "$LOG_FILE" >&2 ; }
gaming_success() { printf "%b[  ok ]%b \xE2\x9C\x85 Gaming stack ready! FPS incoming \xF0\x9F\x9A\x80\n" "${C_GREEN}${C_BOLD}" "${C_RESET}" | tee -a "$LOG_FILE" ; }

banner() {
    printf "%b" "${C_CYAN}${C_BOLD}"
    cat <<'EOF'
 ███████╗██████╗  ██████╗ ███████╗████████╗  ·  gaming & dev stack
 ██╔════╝██╔══██╗██╔═══██╗██╔════╝╚══██╔══╝
 █████╗  ██████╔╝██║   ██║███████╗   ██║      steam · lutris · postgres · rust · go
 ██╔══╝  ██╔══██╗██║   ██║╚════██║   ██║
 ██║     ██║  ██║╚██████╔╝███████║   ██║
 ╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝
EOF
    printf "%b\n" "${C_RESET}"
}

# ─────────────────────────────────────────────────────────────────────────
# 1. STATE TRACKING & ERROR TRAP
# ─────────────────────────────────────────────────────────────────────────

CREATED_DIRS=()
CREATED_FILES=()
BACKED_UP_FILES=()

rollback() {
    local exit_code=$?
    error "Gaming/dev setup failed (exit code $exit_code). Rolling back..."

    for pair in "${BACKED_UP_FILES[@]:-}"; do
        [[ -z "$pair" ]] && continue
        local orig="${pair%%|*}" backup="${pair##*|}"
        if [[ -f "$backup" ]]; then
            cp -f "$backup" "$orig" 2>/dev/null && log "  restored $orig" || warn "  could not restore $orig"
        fi
    done

    for f in "${CREATED_FILES[@]:-}" "${CREATED_DIRS[@]:-}"; do
        [[ -z "$f" ]] && continue
        rm -rf "$f" 2>/dev/null && log "  removed $f" || true
    done

    error "Rollback complete. Full log at: $LOG_FILE"
    exit "$exit_code"
}

trap rollback ERR
trap 'error "Interrupted by user (SIGINT/SIGTERM)."; exit 130' INT TERM

# ─────────────────────────────────────────────────────────────────────────
# 2. ARGUMENT PARSING
# ─────────────────────────────────────────────────────────────────────────

FROST_TARGET="/mnt"
FORCE_LOCAL=false
DRY_RUN=false
SKIP_GAMING=false
SKIP_DEV=false
SKIP_PERFORMANCE=false
SKIP_LAUNCHER=false
SKIP_GPU_TWEAKS=false
RAMDISK_SIZE=""
OVERRIDE_USER=""
OVERRIDE_AUR_HELPER=""

usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} — FROST Gaming & Dev Stack pack

Usage: sudo ./${SCRIPT_NAME} [options]

  --target <path>          pacstrap target from Phase 1 (default: /mnt)
  --local                    Force local mode (provision the running system)
  --username <name>            Target user for AUR builds / desktop integration
  --aur-helper <yay|paru>          Override AUR helper auto-detection
  --skip-gaming                       Skip Steam/Lutris/Heroic/GPU/gamemode
  --skip-dev                             Skip the dev stack (languages/DBs/IDEs)
  --skip-performance                        Skip sysctl tuning, ramdisk, sensors
  --skip-launcher                              Skip the frost --mode gaming/dev wiring
  --skip-gpu-tweaks                               Skip the NVIDIA modeset kernel param
  --ramdisk-size <size>                              tmpfs size for builds (default: auto, capped 8G)
  --dry-run                                             Print what would happen, change nothing
  -h, --help                                              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)           FROST_TARGET="${2:?}"; shift 2 ;;
        --local)             FORCE_LOCAL=true; shift ;;
        --username)          OVERRIDE_USER="${2:?}"; shift 2 ;;
        --aur-helper)        OVERRIDE_AUR_HELPER="${2:?}"; shift 2 ;;
        --skip-gaming)       SKIP_GAMING=true; shift ;;
        --skip-dev)          SKIP_DEV=true; shift ;;
        --skip-performance)  SKIP_PERFORMANCE=true; shift ;;
        --skip-launcher)     SKIP_LAUNCHER=true; shift ;;
        --skip-gpu-tweaks)   SKIP_GPU_TWEAKS=true; shift ;;
        --ramdisk-size)      RAMDISK_SIZE="${2:?}"; shift 2 ;;
        --dry-run)           DRY_RUN=true; shift ;;
        -h|--help)           usage; exit 0 ;;
        *) error "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

run() {
    if [[ "$DRY_RUN" == true ]]; then
        printf "%b[dry-run]%b %s\n" "${C_YELLOW}" "${C_RESET}" "$*"
    else
        "$@"
    fi
}

# ─────────────────────────────────────────────────────────────────────────
# 3. PRE-FLIGHT
# ─────────────────────────────────────────────────────────────────────────

check_root() {
    # See frost-branding.sh's check_root() for why this must be `if`, not a
    # bare `[[ ]] && { ...; exit 1; }` function body — the latter aborts
    # the whole script under set -e on the "we ARE root" path, not just the
    # failure path. Confirmed by an actual VM crash — see ARCHITECTURE.md.
    if [[ "$EUID" -ne 0 ]]; then
        error "Run as root: sudo ./${SCRIPT_NAME}"
        exit 1
    fi
}

check_arch_linux() {
    command -v pacman &>/dev/null || { error "pacman not found — this only runs on Arch Linux."; exit 1; }
}

ROOT_PREFIX=""

detect_mode() {
    if [[ "$FORCE_LOCAL" == true ]]; then
        BUILD_MODE="local"
    elif command -v pacstrap &>/dev/null && mountpoint -q "$FROST_TARGET" 2>/dev/null; then
        BUILD_MODE="bootstrap"
    else
        BUILD_MODE="local"
    fi
    [[ "$BUILD_MODE" == "bootstrap" ]] && ROOT_PREFIX="$FROST_TARGET"
    log "Build mode: ${C_BOLD}${BUILD_MODE}${C_RESET} (root prefix: '${ROOT_PREFIX:-/}')"
}

chroot_exec() {
    if [[ "$BUILD_MODE" == "bootstrap" ]]; then
        arch-chroot "$FROST_TARGET" bash -c "$1"
    else
        bash -c "$1"
    fi
}

ensure_chroot_network() {
    [[ "$BUILD_MODE" != "bootstrap" ]] && return 0
    local resolv="${FROST_TARGET}/etc/resolv.conf"
    if [[ ! -s "$resolv" ]]; then
        log "Copying host /etc/resolv.conf into chroot for network access"
        run cp -L /etc/resolv.conf "$resolv"
        CREATED_FILES+=("$resolv")
    fi
}

TARGET_USER=""
AUR_HELPER=""

detect_target_user() {
    if [[ -n "$OVERRIDE_USER" ]]; then
        TARGET_USER="$OVERRIDE_USER"
    else
        local marker="${ROOT_PREFIX}/opt/frost/state/phase3.marker"
        if [[ -f "$marker" ]]; then
            TARGET_USER="$(grep '^username=' "$marker" | cut -d= -f2)"
            [[ "$TARGET_USER" == "<none>" ]] && TARGET_USER=""
        fi
        if [[ -z "$TARGET_USER" ]]; then
            TARGET_USER="$(chroot_exec "getent passwd | awk -F: '\$3>=1000 && \$3<60000 {print \$1; exit}'" 2>/dev/null || true)"
        fi
    fi
    if [[ -n "$TARGET_USER" ]] && chroot_exec "id -u '${TARGET_USER}' &>/dev/null"; then
        success "Target user for AUR builds / desktop setup: ${TARGET_USER}"
    else
        warn "No usable non-root user found. AUR-only tools will be skipped — pass"
        warn "--username <name>, or run frost-phase3.sh first to create one."
        TARGET_USER=""
    fi
}

detect_aur_helper() {
    if [[ -n "$OVERRIDE_AUR_HELPER" ]]; then
        AUR_HELPER="$OVERRIDE_AUR_HELPER"
    elif chroot_exec "command -v yay &>/dev/null"; then
        AUR_HELPER="yay"
    elif chroot_exec "command -v paru &>/dev/null"; then
        AUR_HELPER="paru"
    else
        AUR_HELPER=""
    fi
    if [[ -n "$AUR_HELPER" ]]; then
        success "AUR helper detected: ${AUR_HELPER}"
    else
        warn "No AUR helper found (run frost-phase2.sh first). AUR-only tools will be skipped."
    fi
}

check_disk_space() {
    step "Disk space check"
    local check_path="${ROOT_PREFIX:-/}"
    local avail_kb
    avail_kb="$(df -Pk "$check_path" 2>/dev/null | awk 'NR==2{print $4}')"
    if [[ -z "$avail_kb" ]]; then
        warn "Could not determine free space on ${check_path}, continuing anyway."
        return 0
    fi
    local avail_gb=$((avail_kb / 1024 / 1024))
    if (( avail_kb < 5 * 1024 * 1024 )); then
        space_warn
        warn "Only ~${avail_gb}GB free on ${check_path} — this pack installs several GB"
        warn "(Steam+Lutris+Heroic+GPU drivers+dev stack easily runs 5-10GB). Consider"
        warn "freeing space first (pacman -Sc, docker system prune) or use --skip-gaming/"
        warn "--skip-dev to install a smaller subset."
    else
        success "~${avail_gb}GB free on ${check_path}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────
# 4. GPU DETECTION
# ─────────────────────────────────────────────────────────────────────────

GPU_VENDOR=""

detect_gpu() {
    step "GPU detection"
    local pci_vga
    pci_vga="$(lspci -nn 2>/dev/null | grep -Ei 'vga|3d|display' || true)"

    if [[ -z "$pci_vga" ]]; then
        gpu_error
        warn "lspci found no VGA/3D/display controller at all — driver install will be skipped."
        GPU_VENDOR="none"
        return 0
    fi

    if echo "$pci_vga" | grep -qi 'nvidia'; then
        GPU_VENDOR="nvidia"
    elif echo "$pci_vga" | grep -Eqi 'amd|ati|radeon'; then
        GPU_VENDOR="amd"
    elif echo "$pci_vga" | grep -Eqi 'virtualbox|vmware|qxl|virtio|red hat.*qumranet'; then
        GPU_VENDOR="virtual"
    elif echo "$pci_vga" | grep -qi 'intel'; then
        GPU_VENDOR="intel"
    else
        gpu_error
        warn "GPU present but vendor not recognized from: ${pci_vga}"
        warn "Install the right driver manually; skipping auto-detection here."
        GPU_VENDOR="unknown"
        return 0
    fi
    success "GPU vendor detected: ${GPU_VENDOR} (${pci_vga})"
}

# ─────────────────────────────────────────────────────────────────────────
# 5. GENERIC TOOL INSTALL (same pattern as frost-security.sh's install_tool,
#    IFS fix applied from the start this time — see ARCHITECTURE.md Lesson 2)
# ─────────────────────────────────────────────────────────────────────────

install_tool() {
    local IFS=' '
    local name="$1" official="$2" aur="$3"
    local pkg found=""

    for pkg in $official; do
        if chroot_exec "pacman -Si '${pkg}' &>/dev/null"; then
            if run chroot_exec "pacman -S --needed --noconfirm '${pkg}'"; then
                found="$pkg"
            fi
            break
        fi
    done

    if [[ -z "$found" && -n "$aur" ]]; then
        if [[ -n "$AUR_HELPER" && -n "$TARGET_USER" ]]; then
            for pkg in $aur; do
                if run chroot_exec "sudo -u '${TARGET_USER}' ${AUR_HELPER} -S --needed --noconfirm '${pkg}'"; then
                    found="$pkg"
                    break
                fi
                warn "AUR candidate '${pkg}' failed for ${name}, trying next if any"
            done
        else
            tool_missing "$name"
            warn "  ${name} is AUR-only and no AUR helper/user is available."
            warn "  Once you have one: ${AUR_HELPER:-yay} -S ${aur%% *}"
            return 1
        fi
    fi

    if [[ -z "$found" ]]; then
        tool_missing "$name"
        return 1
    fi

    tool_success "$name"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────
# 6. GAMING LAYER
# ─────────────────────────────────────────────────────────────────────────

install_gpu_driver() {
    case "$GPU_VENDOR" in
        nvidia)
            install_tool "NVIDIA driver" "nvidia nvidia-utils lib32-nvidia-utils nvidia-settings" "" || true
            ;;
        amd)
            install_tool "AMD driver stack" "mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon libva-mesa-driver lib32-libva-mesa-driver" "" || true
            ;;
        intel)
            install_tool "Intel driver stack" "mesa lib32-mesa vulkan-intel lib32-vulkan-intel" "" || true
            ;;
        virtual)
            log "Virtual GPU (VM) detected — installing mesa for software/virtual rendering."
            install_tool "mesa (virtual GPU)" "mesa lib32-mesa" "" || true
            log "Install real vendor drivers instead if this ends up running on bare metal."
            ;;
        none|unknown|"")
            warn "Skipping GPU driver install (no recognized GPU)."
            ;;
    esac
}

apply_gpu_tweaks() {
    [[ "$SKIP_GPU_TWEAKS" == true ]] && { warn "Skipping GPU kernel tweaks (--skip-gpu-tweaks)"; return 0; }
    [[ "$GPU_VENDOR" != "nvidia" ]] && return 0

    step "NVIDIA kernel modeset tweak"
    # nvidia-drm.modeset=1 is the well-established Arch-wiki-documented
    # setting proprietary NVIDIA needs for proper KMS (flicker-free boot,
    # correct Vulkan/Wayland behavior). Bootloader-aware, backed up,
    # idempotent — same merge approach frost-branding.sh uses for GRUB.
    local marker="${ROOT_PREFIX}/opt/frost/state/phase3.marker"
    local bootloader="unknown"
    [[ -f "$marker" ]] && bootloader="$(grep '^bootloader=' "$marker" | cut -d= -f2)"

    if [[ "$bootloader" == "grub" ]]; then
        local grub_default="${ROOT_PREFIX}/etc/default/grub"
        if [[ -f "$grub_default" ]] && ! grep -q 'nvidia-drm.modeset=1' "$grub_default"; then
            local backup="${grub_default}.frost-bak-$(date +%s)"
            run cp -f "$grub_default" "$backup"
            BACKED_UP_FILES+=("${grub_default}|${backup}")
            if [[ "$DRY_RUN" != true ]]; then
                sed -i -E 's/(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*)"/\1 nvidia-drm.modeset=1"/' "$grub_default"
            fi
            run chroot_exec "grub-mkconfig -o /boot/grub/grub.cfg"
            success "nvidia-drm.modeset=1 added to GRUB_CMDLINE_LINUX_DEFAULT"
        else
            log "nvidia-drm.modeset=1 already present (or grub config missing) — skipping"
        fi
    elif [[ "$bootloader" == "systemd-boot" ]]; then
        local entry="${ROOT_PREFIX}/boot/loader/entries/frost.conf"
        if [[ -f "$entry" ]] && ! grep -q 'nvidia-drm.modeset=1' "$entry"; then
            local backup="${entry}.frost-bak-$(date +%s)"
            run cp -f "$entry" "$backup"
            BACKED_UP_FILES+=("${entry}|${backup}")
            run sed -i 's/^options .*/& nvidia-drm.modeset=1/' "$entry"
            success "nvidia-drm.modeset=1 added to ${entry}"
        else
            log "nvidia-drm.modeset=1 already present (or loader entry missing) — skipping"
        fi
    else
        warn "Unknown bootloader ('${bootloader}') — add nvidia-drm.modeset=1 to your kernel"
        warn "command line manually. See GAMING.README.md."
    fi
}

install_gaming_layer() {
    step "Gaming layer"
    if [[ "$SKIP_GAMING" == true ]]; then
        warn "Skipping gaming layer (--skip-gaming)"; return 0
    fi
    ensure_chroot_network

    install_gpu_driver
    apply_gpu_tweaks

    install_tool "Vulkan/OpenGL libs" "vulkan-icd-loader lib32-vulkan-icd-loader vulkan-tools mesa-utils" "" || true
    install_tool "Steam" "steam" "" || true
    install_tool "Lutris" "lutris wine wine-mono wine-gecko winetricks" "" || true
    install_tool "Heroic Games Launcher" "" "heroic-games-launcher-bin" || true
    install_tool "ProtonUp-Qt" "" "protonup-qt" || true
    install_tool "MangoHud" "mangohud lib32-mangohud" "" || true
    install_tool "GameMode" "gamemode lib32-gamemode" "" || true
    install_tool "Discord" "discord" "discord" || true
    install_tool "OBS Studio" "obs-studio" "" || true

    if chroot_exec "command -v gamemoded &>/dev/null"; then
        run chroot_exec "systemctl enable --user gamemoded 2>/dev/null" || true
        log "GameMode installed — launch games with 'gamemoderun %command%' (Steam) or enable it in Lutris's runner options."
    fi

    gaming_success
}

# ─────────────────────────────────────────────────────────────────────────
# 7. DEV STACK
# ─────────────────────────────────────────────────────────────────────────

setup_postgresql() {
    chroot_exec "command -v initdb &>/dev/null" || return 0
    local data_dir="${ROOT_PREFIX}/var/lib/postgres/data"
    if [[ ! -f "${data_dir}/PG_VERSION" ]]; then
        log "Initializing PostgreSQL data directory (not done by the package itself on Arch)"
        run chroot_exec "sudo -u postgres initdb -D /var/lib/postgres/data"
    else
        log "PostgreSQL data directory already initialized"
    fi
    run chroot_exec "systemctl enable postgresql.service"
}

install_dev_stack() {
    step "Dev stack"
    if [[ "$SKIP_DEV" == true ]]; then
        warn "Skipping dev stack (--skip-dev)"; return 0
    fi
    ensure_chroot_network

    log "git/python/nodejs/docker already come from Phase 1 — reinforcing with --needed"
    install_tool "core toolchain (git/python/nodejs/docker)" "git python python-pip nodejs npm docker docker-compose" "" || true

    install_tool "Rust" "rust" "" || true
    install_tool "Go" "go" "" || true
    install_tool "OpenJDK" "jdk-openjdk" "" || true
    install_tool "GitHub CLI" "github-cli" "" || true

    install_tool "PostgreSQL" "postgresql" "" || true
    setup_postgresql
    install_tool "Redis" "redis" "" || true
    run chroot_exec "systemctl enable redis.service" || true
    install_tool "MongoDB" "" "mongodb-bin mongodb" || true

    install_tool "VSCode" "" "visual-studio-code-bin" || true
    install_tool "JetBrains Toolbox" "" "jetbrains-toolbox" || true

    run chroot_exec "systemctl enable docker.service" || true
    success "Dev stack ready — languages: python/node/rust/go/java, DBs: postgres/redis/mongo"
}

# ─────────────────────────────────────────────────────────────────────────
# 8. PERFORMANCE TUNING
# ─────────────────────────────────────────────────────────────────────────

setup_ramdisk() {
    local size="$RAMDISK_SIZE"
    if [[ -z "$size" ]]; then
        # Auto: 25% of detected RAM, capped at 8G, floor of 1G.
        local mem_kb
        mem_kb="$(chroot_exec "awk '/MemTotal/{print \$2}' /proc/meminfo" 2>/dev/null || echo 0)"
        local quarter_gb=$(( mem_kb / 1024 / 1024 / 4 ))
        (( quarter_gb < 1 )) && quarter_gb=1
        (( quarter_gb > 8 )) && quarter_gb=8
        size="${quarter_gb}G"
    fi

    local mount_point="/mnt/ramdisk-build"
    run mkdir -p "${ROOT_PREFIX}${mount_point}"
    CREATED_DIRS+=("${ROOT_PREFIX}${mount_point}")

    local fstab="${ROOT_PREFIX}/etc/fstab"
    if [[ -f "$fstab" ]] && ! grep -q "$mount_point" "$fstab"; then
        local backup="${fstab}.frost-bak-$(date +%s)"
        run cp -f "$fstab" "$backup"
        BACKED_UP_FILES+=("${fstab}|${backup}")
        if [[ "$DRY_RUN" != true ]]; then
            echo "tmpfs ${mount_point} tmpfs rw,nodev,nosuid,size=${size} 0 0" >> "$fstab"
        fi
        success "RAM disk configured: ${mount_point} (tmpfs, ${size}, mounted on next boot)"
        log "Volatile by design — point build tools (CARGO_TARGET_DIR, npm cache, ccache) at"
        log "it for a speed boost, but never store anything you need to survive a reboot there."
    else
        log "RAM disk entry already present in fstab (or fstab missing) — skipping"
    fi
}

setup_sysctl_tuning() {
    local sysctl_file="${ROOT_PREFIX}/etc/sysctl.d/99-frost-performance.conf"
    run mkdir -p "$(dirname "$sysctl_file")"
    if [[ "$DRY_RUN" != true ]]; then
        cat > "$sysctl_file" <<'EOF'
# FROST performance tuning — installed by frost-gaming.sh
# Lower swappiness: prefer keeping things in RAM (desktop/gaming
# responsiveness) over the server-oriented default of 60.
vm.swappiness = 10
# Keep filesystem metadata cached longer — helps build-heavy dev
# workloads (repeated compiles hitting the same tree of small files).
vm.vfs_cache_pressure = 50
EOF
    fi
    CREATED_FILES+=("$sysctl_file")
    run chroot_exec "sysctl --system" || true
    success "sysctl tuning applied (vm.swappiness=10, vm.vfs_cache_pressure=50)"
}

setup_thermal_monitoring() {
    install_tool "lm_sensors" "lm_sensors" "" || true
    if chroot_exec "command -v sensors-detect &>/dev/null"; then
        log "Running sensors-detect --auto (non-interactive autodetect, safe default)"
        run chroot_exec "sensors-detect --auto" || warn "sensors-detect --auto reported an issue — run 'sudo sensors-detect' by hand"
    fi
    install_tool "fancontrol" "fancontrol" "" || true
    warn "fancontrol needs 'sudo pwmconfig' run interactively (it tests fans one at a time"
    warn "and asks you which is which) — deliberately NOT automated here, wrong fan curves"
    warn "can mean real overheating. See GAMING.README.md for the manual steps."
}

setup_performance() {
    step "Performance tuning"
    if [[ "$SKIP_PERFORMANCE" == true ]]; then
        warn "Skipping performance tuning (--skip-performance)"; return 0
    fi
    ensure_chroot_network
    setup_sysctl_tuning
    setup_ramdisk
    setup_thermal_monitoring
}

# ─────────────────────────────────────────────────────────────────────────
# 9. CUSTOM LAUNCHER — frost --mode gaming|dev
# ─────────────────────────────────────────────────────────────────────────

setup_frost_mode() {
    step "frost --mode launcher"
    if [[ "$SKIP_LAUNCHER" == true ]]; then
        warn "Skipping frost --mode wiring (--skip-launcher)"; return 0
    fi

    local bin_dir="${ROOT_PREFIX}/opt/frost/bin"
    run mkdir -p "$bin_dir"
    local mode_script="${bin_dir}/frost-mode"
    local is_new=true
    [[ -f "$mode_script" ]] && is_new=false

    if [[ "$DRY_RUN" != true ]]; then
        cat > "$mode_script" <<'FROST_MODE_EOF'
#!/usr/bin/env bash
# frost-mode — switch FROST between gaming and dev resource profiles.
# Installed by frost-gaming.sh; dispatched from frost-cli's --mode flag.
set -euo pipefail

MODE="${1:-}"
DEV_SERVICES="docker postgresql redis"

gaming_mode() {
    echo "🚀 Switching to gaming mode..."
    for svc in $DEV_SERVICES; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            sudo systemctl stop "$svc" && echo "  stopped $svc"
        fi
    done
    if command -v cpupower &>/dev/null; then
        sudo cpupower frequency-set -g performance &>/dev/null \
            && echo "  CPU governor: performance"
    fi
    echo "✅ Gaming mode active. Dev services stopped, CPU set to performance."
    echo "   Launch games via 'gamemoderun %command%' (Steam) for the full effect."
}

dev_mode() {
    echo "💻 Switching to dev mode..."
    for svc in $DEV_SERVICES; do
        if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            sudo systemctl start "$svc" && echo "  started $svc"
        fi
    done
    if command -v cpupower &>/dev/null; then
        (sudo cpupower frequency-set -g schedutil ||
         sudo cpupower frequency-set -g ondemand) &>/dev/null \
            && echo "  CPU governor: balanced"
    fi
    echo "✅ Dev mode active. Docker/Postgres/Redis started, CPU set to balanced."
}

case "$MODE" in
    gaming) gaming_mode ;;
    dev)    dev_mode ;;
    *)
        echo "Usage: frost --mode <gaming|dev>"
        exit 1
        ;;
esac
FROST_MODE_EOF
        chmod 755 "$mode_script"
    fi
    $is_new && CREATED_FILES+=("$mode_script")
    success "frost-mode installed → ${mode_script}"

    # Idempotently wire "--mode" into frost-cli (installed by frost-phase2.sh)
    # if it's already deployed on this target.
    local cli="${bin_dir}/frost-cli"
    if [[ -f "$cli" ]] && ! grep -q -- '--mode' "$cli"; then
        local backup="${cli}.frost-bak-$(date +%s)"
        run cp -f "$cli" "$backup"
        BACKED_UP_FILES+=("${cli}|${backup}")
        if [[ "$DRY_RUN" != true ]]; then
            sed -i '/^case "\${1:-help}" in/a\
    --mode)  shift; [[ -x /opt/frost/bin/frost-mode ]] && /opt/frost/bin/frost-mode "${1:-}" || echo "frost-mode not installed — run frost-gaming.sh"; ;;' "$cli"
            sed -i '/^  update    Update official + AUR packages$/a\
  --mode <gaming|dev>  Switch resource profile (needs frost-gaming.sh)' "$cli"
        fi
        success "frost-cli patched: 'frost --mode gaming|dev' now dispatches to frost-mode"
    elif [[ -f "$cli" ]]; then
        log "frost-cli already wired for --mode — skipping patch"
    else
        warn "frost-cli not found at ${cli} (run frost-phase2.sh first) — frost-mode is"
        warn "installed and usable directly: /opt/frost/bin/frost-mode <gaming|dev>"
    fi
}

# ─────────────────────────────────────────────────────────────────────────
# 10. MAIN
# ─────────────────────────────────────────────────────────────────────────

write_marker() {
    [[ "$DRY_RUN" == true ]] && return 0
    local marker="${ROOT_PREFIX}/opt/frost/state/gaming.marker"
    mkdir -p "$(dirname "$marker")"
    cat > "$marker" <<EOF
name=gaming-and-dev-stack
target_user=${TARGET_USER:-<none>}
aur_helper=${AUR_HELPER:-<none>}
gpu_vendor=${GPU_VENDOR:-<none>}
gaming=$([[ "$SKIP_GAMING" != true ]] && echo true || echo false)
dev=$([[ "$SKIP_DEV" != true ]] && echo true || echo false)
performance=$([[ "$SKIP_PERFORMANCE" != true ]] && echo true || echo false)
launcher=$([[ "$SKIP_LAUNCHER" != true ]] && echo true || echo false)
completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
script_version=${SCRIPT_VERSION}
EOF
    CREATED_FILES+=("$marker")
}

main() {
    banner
    log "FROST gaming/dev pack starting — log: $LOG_FILE"
    [[ "$DRY_RUN" == true ]] && warn "DRY-RUN MODE: no changes will be made."

    check_root
    check_arch_linux
    detect_mode
    check_disk_space
    detect_target_user
    detect_aur_helper
    detect_gpu

    install_gaming_layer
    install_dev_stack
    setup_performance
    setup_frost_mode
    write_marker

    trap - ERR

    step "FROST gaming/dev pack complete"
    success "GPU vendor    : ${GPU_VENDOR:-<none>}"
    success "Target user   : ${TARGET_USER:-<none>}"
    success "Gaming layer  : $([[ $SKIP_GAMING == true ]] && echo skipped || echo installed)"
    success "Dev stack     : $([[ $SKIP_DEV == true ]] && echo skipped || echo installed)"
    success "Performance   : $([[ $SKIP_PERFORMANCE == true ]] && echo skipped || echo tuned)"
    success "frost --mode  : $([[ $SKIP_LAUNCHER == true ]] && echo skipped || echo wired)"
    success "Log file      : ${LOG_FILE}"
    printf "\n%b🚀 Try: frost --mode gaming   (or --mode dev)%b\n\n" "${C_CYAN}${C_BOLD}" "${C_RESET}"
}

main "$@"
