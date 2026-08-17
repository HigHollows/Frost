#!/usr/bin/env bash
#
# ███████╗██████╗  ██████╗ ███████╗████████╗
# ██╔════╝██╔══██╗██╔═══██╗██╔════╝╚══██╔══╝
# █████╗  ██████╔╝██║   ██║███████╗   ██║
# ██╔══╝  ██╔══██╗██║   ██║╚════██║   ██║
# ██║     ██║  ██║╚██████╔╝███████║   ██║
# ╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝
#
# frost-build.sh — FROST Linux, Phase 1: Fondations
#
# Minimalist Arch Linux distro build script, tailored for full-stack devs.
# Builds a target rootfs (live ISO + pacstrap) OR provisions the running
# Arch host directly (local/dev mode) — auto-detected.
#
# Usage:
#   sudo ./frost-build.sh [--target /mnt] [--local] [--dry-run]
#
# See frost-build.README.md for full documentation.
#
# Author: FROST project
# License: MIT

set -euo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────
# 0. GLOBALS & "NERDY" COLOR OUTPUT
# ─────────────────────────────────────────────────────────────────────────

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="0.1.0-phase1"
readonly LOG_FILE="/tmp/frost-build-$(date +%Y%m%d-%H%M%S).log"

# Colors (fall back to no color if not a tty)
if [[ -t 1 ]]; then
    C_RED='\033[1;31m'
    C_GREEN='\033[1;32m'
    C_YELLOW='\033[1;33m'
    C_BLUE='\033[1;34m'
    C_CYAN='\033[1;36m'
    C_BOLD='\033[1m'
    C_RESET='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_BOLD=''; C_RESET=''
fi

log()     { printf "%b[frost]%b %s\n" "${C_CYAN}${C_BOLD}" "${C_RESET}" "$*" | tee -a "$LOG_FILE" ; }
success() { printf "%b[  ok ]%b %s\n" "${C_GREEN}${C_BOLD}" "${C_RESET}" "$*" | tee -a "$LOG_FILE" ; }
warn()    { printf "%b[ warn]%b %s\n" "${C_YELLOW}${C_BOLD}" "${C_RESET}" "$*" | tee -a "$LOG_FILE" >&2 ; }
error()   { printf "%b[FATAL]%b %s\n" "${C_RED}${C_BOLD}" "${C_RESET}" "$*" | tee -a "$LOG_FILE" >&2 ; }
step()    { printf "\n%b==>%b %b%s%b\n" "${C_BLUE}${C_BOLD}" "${C_RESET}" "${C_BOLD}" "$*" "${C_RESET}" | tee -a "$LOG_FILE" ; }

banner() {
    printf "%b" "${C_CYAN}${C_BOLD}"
    cat <<'EOF'
 ███████╗██████╗  ██████╗ ███████╗████████╗
 ██╔════╝██╔══██╗██╔═══██╗██╔════╝╚══██╔══╝
 █████╗  ██████╔╝██║   ██║███████╗   ██║
 ██╔══╝  ██╔══██╗██║   ██║╚════██║   ██║
 ██║     ██║  ██║╚██████╔╝███████║   ██║
 ╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝
        minimalist Arch for full-stack devs
EOF
    printf "%b\n" "${C_RESET}"
}

# ─────────────────────────────────────────────────────────────────────────
# 1. STATE TRACKING (for rollback) & ERROR TRAP
# ─────────────────────────────────────────────────────────────────────────

# Tracks what THIS run has actually changed, so rollback only undoes our own mess.
PACMAN_CONF_BACKUP=""
CREATED_DIRS=()
MOUNTED_TARGET=false
BASE_INSTALLED=false

rollback() {
    local exit_code=$?
    error "Build failed (exit code $exit_code). Rolling back changes..."

    if [[ -n "$PACMAN_CONF_BACKUP" && -f "$PACMAN_CONF_BACKUP" ]]; then
        warn "Restoring original pacman.conf from $PACMAN_CONF_BACKUP"
        cp -f "$PACMAN_CONF_BACKUP" /etc/pacman.conf 2>/dev/null \
            && success "pacman.conf restored" \
            || error "Could not restore pacman.conf — check $PACMAN_CONF_BACKUP manually"
    fi

    if [[ "${#CREATED_DIRS[@]}" -gt 0 ]]; then
        warn "Removing directories created by this run..."
        for d in "${CREATED_DIRS[@]}"; do
            # Guard: never rm anything outside /opt/frost or a pacstrap target
            if [[ "$d" == /opt/frost* || "$d" == "${FROST_TARGET:-/nonexistent}"* ]]; then
                rm -rf "$d" 2>/dev/null && log "  removed $d" || warn "  could not remove $d"
            fi
        done
    fi

    if [[ "$MOUNTED_TARGET" == true ]]; then
        warn "Unmounting target filesystem(s) under $FROST_TARGET..."
        umount -R "$FROST_TARGET" 2>/dev/null || warn "  umount failed, may need manual cleanup"
    fi

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

usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} — FROST build script (Phase 1: Foundations)

Usage: sudo ./${SCRIPT_NAME} [options]

Options:
  --target <path>   Target mountpoint for pacstrap bootstrap (default: /mnt)
  --local            Force local mode: install onto the currently running
                      system instead of bootstrapping a new rootfs
  --dry-run          Print what would happen, change nothing
  -h, --help          Show this help

EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)  FROST_TARGET="${2:?--target requires a path}"; shift 2 ;;
        --local)   FORCE_LOCAL=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) error "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

run() {
    # Wrapper so --dry-run can no-op any state-changing command uniformly.
    if [[ "$DRY_RUN" == true ]]; then
        printf "%b[dry-run]%b %s\n" "${C_YELLOW}" "${C_RESET}" "$*"
    else
        "$@"
    fi
}

# ─────────────────────────────────────────────────────────────────────────
# 3. PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error "This script must be run as root (needed for pacman/pacstrap)."
        error "Try: sudo ./${SCRIPT_NAME}"
        exit 1
    fi
}

check_arch_linux() {
    if ! command -v pacman &>/dev/null; then
        error "pacman not found. This script only runs on Arch Linux (or the Arch ISO)."
        exit 1
    fi
}

detect_mode() {
    # Bootstrap mode = we're on the live ISO and pacstrap exists → build a
    # fresh rootfs at $FROST_TARGET. Local mode = provision the host we're
    # already running on (useful for dev/testing individual phases).
    if [[ "$FORCE_LOCAL" == true ]]; then
        BUILD_MODE="local"
    elif command -v pacstrap &>/dev/null; then
        BUILD_MODE="bootstrap"
    else
        BUILD_MODE="local"
    fi
    log "Build mode: ${C_BOLD}${BUILD_MODE}${C_RESET} (target: ${FROST_TARGET})"
}

# ─────────────────────────────────────────────────────────────────────────
# 4. STEP 1 — ARCHITECTURE DETECTION
# ─────────────────────────────────────────────────────────────────────────

detect_architecture() {
    step "Detecting system architecture"
    local raw_arch
    raw_arch="$(uname -m)"

    case "$raw_arch" in
        x86_64)
            FROST_ARCH="x86_64"
            PACMAN_ARCH_REPOS=("core" "extra" "multilib")
            ;;
        aarch64|arm64)
            FROST_ARCH="aarch64"
            # Vanilla Arch has no official ARM repos; ARM builds rely on
            # Arch Linux ARM (archlinuxarm.org) mirrors instead of multilib.
            PACMAN_ARCH_REPOS=("core" "extra")
            warn "ARM detected: multilib is unavailable, using Arch Linux ARM repo layout."
            ;;
        armv7l)
            FROST_ARCH="armv7h"
            PACMAN_ARCH_REPOS=("core" "extra")
            warn "32-bit ARM detected: FROST support here is best-effort."
            ;;
        *)
            error "Unsupported architecture: '$raw_arch'. FROST supports x86_64 and ARM (aarch64/armv7l)."
            exit 1
            ;;
    esac

    success "Architecture: ${FROST_ARCH} (kernel reports: ${raw_arch})"
}

# ─────────────────────────────────────────────────────────────────────────
# 5. STEP 2 — PACMAN CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────

configure_pacman() {
    step "Configuring pacman"

    local pacman_conf="/etc/pacman.conf"
    if [[ "$BUILD_MODE" == "bootstrap" ]]; then
        # Configure the LIVE environment's pacman.conf; pacstrap copies the
        # resulting mirror/repo behavior into the target via its own conf
        # (mkarchroot semantics) — here we still tune the host copy since
        # pacstrap reads it for the initial package fetch.
        pacman_conf="/etc/pacman.conf"
    fi

    if [[ ! -f "$pacman_conf" ]]; then
        error "pacman.conf not found at $pacman_conf"
        exit 1
    fi

    PACMAN_CONF_BACKUP="${pacman_conf}.frost-bak-$(date +%s)"
    log "Backing up $pacman_conf -> $PACMAN_CONF_BACKUP"
    run cp -f "$pacman_conf" "$PACMAN_CONF_BACKUP"

    if [[ "$DRY_RUN" == true ]]; then
        log "(dry-run) would enable Color, ParallelDownloads, multilib in $pacman_conf"
    else
        # Enable colored pacman output (nerdy points) and parallel downloads.
        sed -i 's/^#Color/Color/' "$pacman_conf"
        grep -q '^ILoveCandy' "$pacman_conf" || sed -i '/^Color/a ILoveCandy' "$pacman_conf"
        if grep -q '^#ParallelDownloads' "$pacman_conf"; then
            sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' "$pacman_conf"
        elif ! grep -q '^ParallelDownloads' "$pacman_conf"; then
            sed -i '/^\[options\]/a ParallelDownloads = 10' "$pacman_conf"
        fi

        # Enable multilib only on x86_64 (32-bit compat libs, useful for devs).
        if [[ "$FROST_ARCH" == "x86_64" ]]; then
            if grep -q '^#\[multilib\]' "$pacman_conf"; then
                sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' "$pacman_conf"
                success "multilib repo enabled"
            elif grep -q '^\[multilib\]' "$pacman_conf"; then
                log "multilib repo already enabled"
            fi
        fi
    fi

    log "Refreshing package databases (pacman -Syy)"
    run pacman -Syy --noconfirm

    success "pacman configured (repos: ${PACMAN_ARCH_REPOS[*]})"
}

# ─────────────────────────────────────────────────────────────────────────
# 6. STEP 3 — MINIMAL BASE SYSTEM
# ─────────────────────────────────────────────────────────────────────────

install_base_system() {
    step "Installing minimal base system"

    # mkinitcpio is listed explicitly: recent pacman versions treat the
    # initramfs generator as a virtual package with multiple providers
    # (mkinitcpio/booster/dracut) and will stop to interactively ask which
    # one to use if none is named explicitly — fatal for a non-interactive
    # bootstrap. Naming it here removes the ambiguity, no prompt.
    local base_pkgs=(base linux linux-firmware mkinitcpio sudo networkmanager)

    if [[ "$FROST_ARCH" == "aarch64" || "$FROST_ARCH" == "armv7h" ]]; then
        # linux-firmware is x86-oriented; on ARM boards firmware usually
        # ships as a board-specific package. Fall back gracefully.
        base_pkgs=(base linux mkinitcpio sudo networkmanager)
        warn "ARM build: skipping generic linux-firmware (use your board's firmware package)."
    fi

    if [[ "$BUILD_MODE" == "bootstrap" ]]; then
        if [[ ! -d "$FROST_TARGET" ]]; then
            log "Creating target mountpoint: $FROST_TARGET"
            run mkdir -p "$FROST_TARGET"
        fi
        if ! mountpoint -q "$FROST_TARGET" 2>/dev/null && [[ "$DRY_RUN" != true ]]; then
            error "$FROST_TARGET is not a mounted filesystem. Partition/format/mount your target disk first."
            error "Example: mount /dev/sdaX $FROST_TARGET"
            exit 1
        fi
        MOUNTED_TARGET=true

        log "Running pacstrap: ${base_pkgs[*]}"
        run pacstrap -K "$FROST_TARGET" "${base_pkgs[@]}"
    else
        log "Local mode: installing base packages onto running system"
        log "Packages: ${base_pkgs[*]}"
        run pacman -S --needed --noconfirm "${base_pkgs[@]}"
    fi

    BASE_INSTALLED=true
    success "Base system installed (${base_pkgs[*]})"
}

# ─────────────────────────────────────────────────────────────────────────
# 7. STEP 4 — DEV TOOLCHAIN
# ─────────────────────────────────────────────────────────────────────────

install_dev_tools() {
    step "Installing full-stack dev toolchain"

    # Split so one bad/renamed package doesn't nuke the whole batch silently.
    local core_dev=(git curl wget htop tmux neovim python python-pip)
    local editors=(code)                 # VSCode: AUR in strict-Arch, official on most spins; see README
    local containers=(docker docker-compose)
    local runtime=(nodejs npm)

    local all_pkgs=("${core_dev[@]}" "${containers[@]}" "${runtime[@]}")

    log "Core CLI tools: ${core_dev[*]}"
    log "Containers:     ${containers[*]}"
    log "JS runtime:     ${runtime[*]}"

    if [[ "$BUILD_MODE" == "bootstrap" ]]; then
        run arch-chroot "$FROST_TARGET" pacman -S --needed --noconfirm "${all_pkgs[@]}"
    else
        run pacman -S --needed --noconfirm "${all_pkgs[@]}"
    fi
    success "Dev toolchain installed"

    # VSCode is not in official Arch repos (it's in the AUR as 'visual-studio-code-bin').
    # We don't assume an AUR helper is present — surface it instead of failing the build.
    step "VSCode (editors)"
    warn "VSCode ('code') is not in the official Arch repos — it lives in the AUR."
    warn "FROST does not install AUR packages during base build (no trusted AUR helper assumed)."
    warn "Post-install, run one of:"
    warn "  yay -S visual-studio-code-bin      # if you use yay"
    warn "  paru -S visual-studio-code-bin     # if you use paru"
    log "This is logged, not fatal — Phase 2 will add an optional AUR-helper bootstrap."

    if [[ "$BUILD_MODE" == "bootstrap" ]]; then
        log "Enabling docker.service in target chroot"
        run arch-chroot "$FROST_TARGET" systemctl enable docker.service
        run arch-chroot "$FROST_TARGET" systemctl enable NetworkManager.service
    else
        log "Enabling docker.service on host"
        run systemctl enable docker.service 2>/dev/null || warn "Could not enable docker.service (systemd not PID 1? container env?)"
        run systemctl enable NetworkManager.service 2>/dev/null || warn "Could not enable NetworkManager.service"
    fi
}

# ─────────────────────────────────────────────────────────────────────────
# 8. STEP 5 — /opt/frost/ STRUCTURE
# ─────────────────────────────────────────────────────────────────────────

create_frost_structure() {
    step "Creating /opt/frost/ directory structure"

    local root_prefix=""
    [[ "$BUILD_MODE" == "bootstrap" ]] && root_prefix="$FROST_TARGET"

    local frost_root="${root_prefix}/opt/frost"
    local subdirs=(
        "bin"        # frost-* helper CLIs (Phase 2+)
        "config"     # distro-level default configs
        "scripts"    # provisioning / post-install scripts
        "cache"      # build & package cache
        "logs"       # frost tooling logs
        "state"      # build/version state (installed phase markers)
    )

    for sub in "${subdirs[@]}"; do
        local d="${frost_root}/${sub}"
        if [[ ! -d "$d" ]]; then
            run mkdir -p "$d"
            CREATED_DIRS+=("$d")
            log "  created $d"
        else
            log "  exists  $d (left untouched)"
        fi
    done

    if [[ "$DRY_RUN" != true ]]; then
        run chmod 755 "$frost_root"
        cat > "${frost_root}/state/phase1.marker" <<EOF
phase=1
name=foundations
arch=${FROST_ARCH}
build_mode=${BUILD_MODE}
completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
script_version=${SCRIPT_VERSION}
EOF
        CREATED_DIRS+=("${frost_root}/state/phase1.marker")
    fi

    success "/opt/frost/ structure ready at ${frost_root}"
}

# ─────────────────────────────────────────────────────────────────────────
# 9. MAIN
# ─────────────────────────────────────────────────────────────────────────

main() {
    banner
    log "FROST build starting — log: $LOG_FILE"
    [[ "$DRY_RUN" == true ]] && warn "DRY-RUN MODE: no changes will be made."

    check_root
    check_arch_linux
    detect_mode
    detect_architecture
    configure_pacman
    install_base_system
    install_dev_tools
    create_frost_structure

    trap - ERR   # build succeeded, disarm rollback trap

    step "FROST Phase 1 complete"
    success "Architecture : ${FROST_ARCH}"
    success "Mode         : ${BUILD_MODE}"
    success "Target       : ${FROST_TARGET}"
    success "Log file     : ${LOG_FILE}"
    printf "\n%b🧊 FROST foundations are laid. Onward to Phase 2.%b\n\n" "${C_CYAN}${C_BOLD}" "${C_RESET}"
}

main "$@"
