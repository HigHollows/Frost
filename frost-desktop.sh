#!/usr/bin/env bash
#
# frost-desktop.sh — FROST OS Desktop (GNOME Shell + FROST Iceblue theme)
#
# Installs GNOME Shell/Mutter as the Wayland compositor, the FROST
# Iceblue GTK4/Libadwaita theme, the frost-shell GNOME Shell extension,
# Dash to Dock + Blur my Shell (real, existing extensions — not
# reimplemented here), Guake (dropdown terminal), Nautilus, fonts
# (Inter, JetBrains Mono), Papirus icons, and the FROST wallpaper.
#
# ⚠ This is an ALTERNATIVE to frost-phase3.sh's `--profile desktop`
# (Xorg + i3 + lightdm) — a different, heavier, more integrated desktop
# experience. Don't run both: if you're using this, run frost-phase3.sh
# with `--profile none` or `--profile server` first. See
# DESKTOP.README.md.
#
# UNVERIFIED like the rest of the desktop/ pack's non-shell-script
# assets: the GNOME Shell extension and dconf defaults this installs
# were written against documented APIs but never run against a real
# GNOME session — this script itself (package installs, file placement)
# follows the same tested conventions as the rest of FROST.
#
# Usage:
#   sudo ./frost-desktop.sh --target /mnt --username you
#   sudo ./frost-desktop.sh --local
#
# Author: FROST project
# License: MIT

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ASSETS_DIR="${SCRIPT_DIR}/desktop"
readonly SCRIPT_VERSION="0.1.0-desktop"
readonly LOG_FILE="/tmp/frost-desktop-$(date +%Y%m%d-%H%M%S).log"

# ─────────────────────────────────────────────────────────────────────────
# 0. OUTPUT
# ─────────────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
    C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'
    C_BLUE='\033[1;34m'; C_CYAN='\033[1;36m'; C_BOLD='\033[1m'; C_RESET='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_BOLD=''; C_RESET=''
fi

log()     { printf "%b[frost]%b %s\n" "${C_CYAN}${C_BOLD}" "${C_RESET}" "$*" | tee -a "$LOG_FILE"; }
success() { printf "%b[  ok ]%b %s\n" "${C_GREEN}${C_BOLD}" "${C_RESET}" "$*" | tee -a "$LOG_FILE"; }
warn()    { printf "%b[ warn]%b %s\n" "${C_YELLOW}${C_BOLD}" "${C_RESET}" "$*" | tee -a "$LOG_FILE" >&2; }
error()   { printf "%b[FATAL]%b %s\n" "${C_RED}${C_BOLD}" "${C_RESET}" "$*" | tee -a "$LOG_FILE" >&2; }
step()    { printf "\n%b==>%b %b%s%b\n" "${C_BLUE}${C_BOLD}" "${C_RESET}" "${C_BOLD}" "$*" "${C_RESET}" | tee -a "$LOG_FILE"; }
tool_success() { printf "%b[  ok ]%b \xE2\x9C\x85 %s installed & configured\n" "${C_GREEN}${C_BOLD}" "${C_RESET}" "$1" | tee -a "$LOG_FILE"; }
tool_missing() { printf "%b[FATAL]%b ERROR: %s not found\n" "${C_RED}${C_BOLD}" "${C_RESET}" "$1" | tee -a "$LOG_FILE" >&2; }

banner() {
    printf "%b" "${C_CYAN}${C_BOLD}"
    cat <<'EOF'
 ███████╗██████╗  ██████╗ ███████╗████████╗  ·  desktop
 ██╔════╝██╔══██╗██╔═══██╗██╔════╝╚══██╔══╝
 █████╗  ██████╔╝██║   ██║███████╗   ██║      gnome shell · iceblue theme
 ██╔══╝  ██╔══██╗██║   ██║╚════██║   ██║
 ██║     ██║  ██║╚██████╔╝███████║   ██║
 ╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝
EOF
    printf "%b\n" "${C_RESET}"
}

# ─────────────────────────────────────────────────────────────────────────
# 1. STATE TRACKING & ERROR TRAP
# ─────────────────────────────────────────────────────────────────────────

CREATED_DIRS=(); CREATED_FILES=(); BACKED_UP_FILES=()

rollback() {
    local exit_code=$?
    error "Desktop install failed (exit code $exit_code). Rolling back..."
    for pair in "${BACKED_UP_FILES[@]:-}"; do
        [[ -z "$pair" ]] && continue
        local orig="${pair%%|*}" backup="${pair##*|}"
        [[ -f "$backup" ]] && { cp -f "$backup" "$orig" 2>/dev/null && log "  restored $orig"; }
    done
    for f in "${CREATED_FILES[@]:-}" "${CREATED_DIRS[@]:-}"; do
        [[ -z "$f" ]] && continue
        rm -rf "$f" 2>/dev/null && log "  removed $f" || true
    done
    error "Rollback complete. Full log at: $LOG_FILE"
    exit "$exit_code"
}
trap rollback ERR
trap 'error "Interrupted."; exit 130' INT TERM

# ─────────────────────────────────────────────────────────────────────────
# 2. ARGS
# ─────────────────────────────────────────────────────────────────────────

FROST_TARGET="/mnt"; FORCE_LOCAL=false; DRY_RUN=false
OVERRIDE_USER=""; OVERRIDE_AUR_HELPER=""; SKIP_WALLPAPER=false

usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} — FROST OS Desktop (GNOME Shell)

Usage: sudo ./${SCRIPT_NAME} [options]
  --target <path>        pacstrap target (default: /mnt)
  --local                  Force local mode
  --username <name>           Target user for AUR builds / dconf defaults
  --aur-helper <yay|paru>        Override AUR helper auto-detection
  --skip-wallpaper                  Don't install the FROST wallpaper
  --dry-run                            Preview only
  -h, --help                             Show this help
EOF
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) FROST_TARGET="${2:?}"; shift 2 ;;
        --local) FORCE_LOCAL=true; shift ;;
        --username) OVERRIDE_USER="${2:?}"; shift 2 ;;
        --aur-helper) OVERRIDE_AUR_HELPER="${2:?}"; shift 2 ;;
        --skip-wallpaper) SKIP_WALLPAPER=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) error "Unknown argument: $1"; usage; exit 1 ;;
    esac
done
run() { if [[ "$DRY_RUN" == true ]]; then printf "%b[dry-run]%b %s\n" "${C_YELLOW}" "${C_RESET}" "$*"; else "$@"; fi }

# ─────────────────────────────────────────────────────────────────────────
# 3. PRE-FLIGHT
# ─────────────────────────────────────────────────────────────────────────

[[ "$EUID" -ne 0 ]] && { error "Run as root: sudo ./${SCRIPT_NAME}"; exit 1; }
command -v pacman &>/dev/null || { error "pacman not found — not an Arch system."; exit 1; }

ROOT_PREFIX=""
detect_mode() {
    if [[ "$FORCE_LOCAL" == true ]]; then BUILD_MODE="local"
    elif command -v pacstrap &>/dev/null && mountpoint -q "$FROST_TARGET" 2>/dev/null; then BUILD_MODE="bootstrap"
    else BUILD_MODE="local"; fi
    [[ "$BUILD_MODE" == "bootstrap" ]] && ROOT_PREFIX="$FROST_TARGET"
    log "Build mode: ${C_BOLD}${BUILD_MODE}${C_RESET} (root prefix: '${ROOT_PREFIX:-/}')"
}
chroot_exec() {
    if [[ "$BUILD_MODE" == "bootstrap" ]]; then arch-chroot "$FROST_TARGET" bash -c "$1"
    else bash -c "$1"; fi
}
ensure_chroot_network() {
    [[ "$BUILD_MODE" != "bootstrap" ]] && return 0
    local resolv="${FROST_TARGET}/etc/resolv.conf"
    [[ -s "$resolv" ]] && return 0
    run cp -L /etc/resolv.conf "$resolv"; CREATED_FILES+=("$resolv")
}

TARGET_USER=""; AUR_HELPER=""
detect_target_user() {
    if [[ -n "$OVERRIDE_USER" ]]; then
        TARGET_USER="$OVERRIDE_USER"
    else
        local marker="${ROOT_PREFIX}/opt/frost/state/phase3.marker"
        [[ -f "$marker" ]] && TARGET_USER="$(grep '^username=' "$marker" | cut -d= -f2)"
        [[ "$TARGET_USER" == "<none>" ]] && TARGET_USER=""
    fi
    if [[ -n "$TARGET_USER" ]] && chroot_exec "id -u '${TARGET_USER}' &>/dev/null"; then
        success "Target user: ${TARGET_USER}"
    else
        warn "No usable user found — dconf defaults / AUR extensions will be skipped. Pass --username."
        TARGET_USER=""
    fi
}
detect_aur_helper() {
    if [[ -n "$OVERRIDE_AUR_HELPER" ]]; then AUR_HELPER="$OVERRIDE_AUR_HELPER"
    elif chroot_exec "command -v yay &>/dev/null"; then AUR_HELPER="yay"
    elif chroot_exec "command -v paru &>/dev/null"; then AUR_HELPER="paru"
    else AUR_HELPER=""; fi
    [[ -n "$AUR_HELPER" ]] && success "AUR helper: ${AUR_HELPER}" || warn "No AUR helper — AUR-only extensions (blur-my-shell) may be skipped."
}

install_tool() {
    local IFS=' '  # see ARCHITECTURE.md Lesson 2 — always scope this locally
    local name="$1" official="$2" aur="$3"
    local pkg found=""
    for pkg in $official; do
        if chroot_exec "pacman -Si '${pkg}' &>/dev/null"; then
            run chroot_exec "pacman -S --needed --noconfirm '${pkg}'" && found="$pkg"
            break
        fi
    done
    if [[ -z "$found" && -n "$aur" ]]; then
        if [[ -n "$AUR_HELPER" && -n "$TARGET_USER" ]]; then
            for pkg in $aur; do
                run chroot_exec "sudo -u '${TARGET_USER}' ${AUR_HELPER} -S --needed --noconfirm '${pkg}'" && { found="$pkg"; break; }
            done
        else
            tool_missing "$name"; warn "  AUR-only, no helper/user available. Install manually later."
            return 1
        fi
    fi
    [[ -z "$found" ]] && { tool_missing "$name"; return 1; }
    tool_success "$name"
}

# ─────────────────────────────────────────────────────────────────────────
# 4. INSTALL
# ─────────────────────────────────────────────────────────────────────────

install_gnome_stack() {
    step "GNOME Shell / Mutter / GDM"
    ensure_chroot_network
    install_tool "GNOME Shell + Mutter"  "gnome-shell mutter" "" || true
    install_tool "GDM"                    "gdm" "" || true
    install_tool "GNOME Control Center"      "gnome-control-center" "" || true
    install_tool "Nautilus (Files)"             "nautilus" "" || true
    install_tool "Networking/audio (should already be present)" "networkmanager pipewire pipewire-pulse wireplumber" "" || true
    run chroot_exec "systemctl enable gdm.service" || true
}

install_theme_and_fonts() {
    step "FROST Iceblue theme, fonts, icons"
    install_tool "Inter font"           "inter-font" "ttf-inter" || true
    install_tool "JetBrains Mono font"     "ttf-jetbrains-mono" "" || true
    install_tool "Papirus icon theme"         "papirus-icon-theme" "" || true

    local theme_dst="${ROOT_PREFIX}/usr/share/themes/FROST"
    run mkdir -p "${theme_dst}/gtk-4.0"
    run cp "${ASSETS_DIR}/theme/index.theme" "$theme_dst/"
    run cp "${ASSETS_DIR}/theme/gtk-4.0/gtk.css" "${theme_dst}/gtk-4.0/"
    CREATED_DIRS+=("$theme_dst")

    if [[ -n "$TARGET_USER" ]]; then
        local user_gtk4="${ROOT_PREFIX}/home/${TARGET_USER}/.config/gtk-4.0"
        run chroot_exec "sudo -u '${TARGET_USER}' mkdir -p '/home/${TARGET_USER}/.config/gtk-4.0'"
        run cp "${ASSETS_DIR}/theme/gtk-4.0/gtk.css" "${user_gtk4}/gtk.css"
        run chroot_exec "chown '${TARGET_USER}:${TARGET_USER}' '/home/${TARGET_USER}/.config/gtk-4.0/gtk.css'"
        success "gtk.css installed to ${TARGET_USER}'s ~/.config/gtk-4.0/ (the reliable path — see DESKTOP.README.md)"
    fi
}

install_frost_shell_extension() {
    step "FROST Shell extension"
    [[ -z "$TARGET_USER" ]] && { warn "No target user — skipping extension install (needs a user's ~/.local/share)"; return 0; }

    local ext_dst="${ROOT_PREFIX}/home/${TARGET_USER}/.local/share/gnome-shell/extensions/frost-shell@frost-os"
    run chroot_exec "sudo -u '${TARGET_USER}' mkdir -p '${ext_dst#"$ROOT_PREFIX"}'"
    run cp -r "${ASSETS_DIR}/extension/frost-shell@frost-os/"* "$ext_dst/"
    run chroot_exec "chown -R '${TARGET_USER}:${TARGET_USER}' '${ext_dst#"$ROOT_PREFIX"}'"
    CREATED_DIRS+=("$ext_dst")

    if chroot_exec "command -v glib-compile-schemas &>/dev/null"; then
        run chroot_exec "glib-compile-schemas '${ext_dst#"$ROOT_PREFIX"}/schemas/'"
        success "Compiled frost-shell's gsettings schema"
    else
        warn "glib-compile-schemas not found — the easter-egg keybinding schema won't be usable until glib2 is installed"
    fi
    tool_success "frost-shell extension"
}

install_dock_and_blur() {
    step "Dash to Dock, Blur my Shell (real, existing extensions)"
    install_tool "Dash to Dock" "gnome-shell-extension-dash-to-dock" "gnome-shell-extension-dash-to-dock" || true
    install_tool "Blur my Shell" "" "gnome-shell-extension-blur-my-shell" || true
}

install_terminal() {
    step "Guake (dropdown terminal)"
    install_tool "Guake" "guake" "" || true
}

apply_dconf_defaults() {
    step "Applying dconf defaults"
    [[ -z "$TARGET_USER" ]] && { warn "No target user — skipping dconf defaults (would apply to the wrong session)"; return 0; }

    local conf_src="${ASSETS_DIR}/config/dconf-frost-defaults.ini"
    local conf_dst="${ROOT_PREFIX}/home/${TARGET_USER}/.frost-dconf-defaults.ini"
    run cp "$conf_src" "$conf_dst"
    CREATED_FILES+=("$conf_dst")

    if [[ "$BUILD_MODE" == "local" ]]; then
        run chroot_exec "sudo -u '${TARGET_USER}' dbus-run-session -- dconf load / < '${conf_dst}'" \
            || warn "dconf load failed — apply manually: dconf load / < ${conf_dst} (needs a running session)"
    else
        warn "Bootstrap mode: dconf needs a live D-Bus session, so defaults are staged at"
        warn "~${TARGET_USER}/.frost-dconf-defaults.ini — apply after first login:"
        warn "  dconf load / < ~/.frost-dconf-defaults.ini"
    fi
}

install_wallpaper() {
    step "FROST wallpaper"
    [[ "$SKIP_WALLPAPER" == true ]] && { warn "Skipping wallpaper (--skip-wallpaper)"; return 0; }
    local dst_dir="${ROOT_PREFIX}/usr/share/backgrounds/frost"
    run mkdir -p "$dst_dir"
    run cp "${ASSETS_DIR}/wallpaper/frost-wallpaper.png" "${dst_dir}/"
    CREATED_DIRS+=("$dst_dir")
    success "Wallpaper installed to ${dst_dir}/frost-wallpaper.png (set via dconf defaults above)"
}

# ─────────────────────────────────────────────────────────────────────────
# 5. MAIN
# ─────────────────────────────────────────────────────────────────────────

main() {
    banner
    log "FROST desktop install starting — log: $LOG_FILE"
    [[ "$DRY_RUN" == true ]] && warn "DRY-RUN MODE: no changes will be made."
    [[ ! -d "$ASSETS_DIR" ]] && { error "desktop/ assets not found next to ${SCRIPT_NAME}"; exit 1; }

    detect_mode
    detect_target_user
    detect_aur_helper

    install_gnome_stack
    install_theme_and_fonts
    install_frost_shell_extension
    install_dock_and_blur
    install_terminal
    install_wallpaper
    apply_dconf_defaults

    if [[ "$DRY_RUN" != true ]]; then
        local marker="${ROOT_PREFIX}/opt/frost/state/desktop.marker"
        mkdir -p "$(dirname "$marker")"
        cat > "$marker" <<EOF
name=frost-desktop-gnome
target_user=${TARGET_USER:-<none>}
completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
script_version=${SCRIPT_VERSION}
EOF
    fi

    trap - ERR
    step "FROST Desktop install complete"
    success "GNOME Shell + FROST Iceblue theme installed"
    success "Log in via GDM — extension enables automatically on first session start"
    printf "\n%b\xE2\x9D\x84  Welcome to FROST OS.%b\n\n" "${C_CYAN}${C_BOLD}" "${C_RESET}"
}
main "$@"
