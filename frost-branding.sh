#!/usr/bin/env bash
#
# frost-branding.sh — FROST Linux, Boot & Aesthetic pack
#
# Applies FROST's visual identity on top of Phases 1-3:
#   1. GRUB theme (glacier gradient + FROST wordmark + Nerd Font menu) —
#      only when GRUB is actually the installed bootloader; systemd-boot
#      (FROST's UEFI default) has no equivalent theming layer, see
#      BRANDING.README.md.
#   2. Plymouth boot splash (growing-snowflake animation) — works with
#      either bootloader, since it's an initramfs-hook animation, not a
#      bootloader feature.
#   3. /etc/motd — shell-mockup style, with a user-editable tagline and
#      a deliberately fake red error line.
#   4. zsh aliases (git, docker, frost-cli) — opt-in, doesn't change
#      anyone's default shell.
#
# Usage:
#   sudo ./frost-branding.sh --target /mnt
#   sudo ./frost-branding.sh --local --skip-grub
#
# Assets live in ./branding/ next to this script (grub/, plymouth/,
# motd/, zsh/) — see BRANDING.README.md for the full asset list and
# manual integration instructions if you'd rather not run this script.
#
# Author: FROST project
# License: MIT

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ASSETS_DIR="${SCRIPT_DIR}/branding"
readonly SCRIPT_VERSION="0.1.0-branding"
readonly LOG_FILE="/tmp/frost-branding-$(date +%Y%m%d-%H%M%S).log"

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

banner() {
    printf "%b" "${C_CYAN}${C_BOLD}"
    cat <<'EOF'
 ███████╗██████╗  ██████╗ ███████╗████████╗  ·  boot & aesthetic
 ██╔════╝██╔══██╗██╔═══██╗██╔════╝╚══██╔══╝
 █████╗  ██████╔╝██║   ██║███████╗   ██║      grub · plymouth · motd · zsh
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
    error "Branding install failed (exit code $exit_code). Rolling back..."

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
SKIP_GRUB=false
SKIP_PLYMOUTH=false
SKIP_MOTD=false
SKIP_ZSH=false
SKIP_OS_RELEASE=false
TAGLINE=""
NERD_FONT_PKG="" # auto-detected unless overridden

usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} — FROST Boot & Aesthetic pack

Usage: sudo ./${SCRIPT_NAME} [options]

  --target <path>     pacstrap target from Phase 1 (default: /mnt)
  --local              Force local mode (provision the running system)
  --skip-grub            Skip the GRUB theme (auto-skipped if systemd-boot is in use)
  --skip-plymouth         Skip the Plymouth boot splash
  --skip-motd             Skip the /etc/motd install
  --skip-zsh               Skip the zsh aliases
  --skip-os-release          Skip rewriting /etc/os-release (FROST identity, no distro logo)
  --tagline "<text>"        Override the default /etc/motd tagline
  --font-package <name>      Force a specific Nerd Font package name
  --dry-run                    Print what would happen, change nothing
  -h, --help                    Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)        FROST_TARGET="${2:?}"; shift 2 ;;
        --local)         FORCE_LOCAL=true; shift ;;
        --skip-grub)     SKIP_GRUB=true; shift ;;
        --skip-plymouth) SKIP_PLYMOUTH=true; shift ;;
        --skip-motd)     SKIP_MOTD=true; shift ;;
        --skip-zsh)      SKIP_ZSH=true; shift ;;
        --skip-os-release) SKIP_OS_RELEASE=true; shift ;;
        --tagline)       TAGLINE="${2:?}"; shift 2 ;;
        --font-package)  NERD_FONT_PKG="${2:?}"; shift 2 ;;
        --dry-run)       DRY_RUN=true; shift ;;
        -h|--help)       usage; exit 0 ;;
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
    # NOT `[[ ]] && { ...; exit 1; }` as a function's sole statement — when
    # the whole function body is that one guard and it's called bare
    # elsewhere, a false condition makes the FUNCTION return 1, which set -e
    # treats as an ordinary command failure at the call site and aborts the
    # script even on the "we ARE root, all good" path. Confirmed by an
    # actual VM crash — see ARCHITECTURE.md. `if` doesn't have this problem:
    # a false condition with no matching branch makes the whole `if`
    # construct itself return 0.
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

detect_bootloader() {
    # Prefer the Phase 3 marker (authoritative record of what was
    # actually installed); fall back to checking the filesystem.
    local marker="${ROOT_PREFIX}/opt/frost/state/phase3.marker"
    if [[ -f "$marker" ]] && grep -q '^bootloader=grub' "$marker"; then
        ACTIVE_BOOTLOADER="grub"
    elif [[ -d "${ROOT_PREFIX}/boot/grub" ]]; then
        ACTIVE_BOOTLOADER="grub"
    elif [[ -f "$marker" ]] && grep -q '^bootloader=systemd-boot' "$marker"; then
        ACTIVE_BOOTLOADER="systemd-boot"
    elif [[ -d "${ROOT_PREFIX}/boot/loader" ]]; then
        ACTIVE_BOOTLOADER="systemd-boot"
    else
        ACTIVE_BOOTLOADER="unknown"
    fi
    log "Detected bootloader: ${C_BOLD}${ACTIVE_BOOTLOADER}${C_RESET}"
}

# ─────────────────────────────────────────────────────────────────────────
# 4. GRUB THEME
# ─────────────────────────────────────────────────────────────────────────

install_grub_theme() {
    step "GRUB theme"
    if [[ "$SKIP_GRUB" == true ]]; then
        warn "Skipping GRUB theme (--skip-grub)"; return 0
    fi
    if [[ "$ACTIVE_BOOTLOADER" != "grub" ]]; then
        warn "Bootloader is '${ACTIVE_BOOTLOADER}', not grub — GRUB theme doesn't apply."
        warn "systemd-boot (FROST's UEFI default) has no equivalent theme layer;"
        warn "see BRANDING.README.md for what IS available on systemd-boot."
        return 0
    fi

    ensure_chroot_network

    local theme_dir="${ROOT_PREFIX}/boot/grub/themes/frost"
    run mkdir -p "$theme_dir"
    CREATED_DIRS+=("$theme_dir")
    run cp "${ASSETS_DIR}/grub/theme.txt" "$theme_dir/"
    run cp "${ASSETS_DIR}/grub/background.png" "$theme_dir/"
    run cp "${ASSETS_DIR}/grub/frost-logo.png" "$theme_dir/"
    success "Theme files copied to ${theme_dir}"

    # Nerd Font -> GRUB .pf2, so the boot menu uses "Frost Regular" as
    # theme.txt expects. Package name has moved around across Arch
    # releases, so try a short list and degrade gracefully rather than
    # fail the whole script over a font.
    local candidates=("${NERD_FONT_PKG:-}" "ttf-nerd-fonts-noto-mono" "nerd-fonts-noto-mono" "nerd-fonts")
    local installed_pkg=""
    for pkg in "${candidates[@]}"; do
        [[ -z "$pkg" ]] && continue
        if run chroot_exec "pacman -S --needed --noconfirm '${pkg}'"; then
            installed_pkg="$pkg"
            break
        fi
        warn "Package '${pkg}' not found, trying next candidate"
    done

    if [[ -n "$installed_pkg" ]]; then
        local ttf_path
        ttf_path="$(chroot_exec "find /usr/share/fonts -iname '*NotoSansMono*NerdFont*.ttf' -o -iname '*Noto*Mono*Nerd*.ttf' 2>/dev/null | head -n1" || true)"
        if [[ -n "$ttf_path" ]]; then
            run chroot_exec "grub-mkfont --output='/boot/grub/themes/frost/frost-font.pf2' --name='Frost Regular' --size=16 '${ttf_path}'"
            success "Nerd Font converted to GRUB .pf2 (${ttf_path})"
        else
            warn "Installed '${installed_pkg}' but couldn't locate the Noto Sans Mono ttf inside it."
            warn "GRUB will fall back to its built-in font — theme colors/layout still apply."
        fi
    else
        warn "No Nerd Font package found among: ${candidates[*]}"
        warn "Run 'pacman -Ss nerd' on the target to find the current package name,"
        warn "then: grub-mkfont --output=/boot/grub/themes/frost/frost-font.pf2 --name='Frost Regular' --size=16 <ttf>"
    fi

    # Merge frost-grub.cfg key=values into the existing /etc/default/grub
    # (already written by frost-phase3.sh's bootloader step) rather than
    # overwrite it wholesale.
    local grub_default="${ROOT_PREFIX}/etc/default/grub"
    if [[ -f "$grub_default" ]]; then
        local backup="${grub_default}.frost-bak-$(date +%s)"
        run cp -f "$grub_default" "$backup"
        BACKED_UP_FILES+=("${grub_default}|${backup}")

        if [[ "$DRY_RUN" != true ]]; then
            while IFS='=' read -r key value; do
                [[ -z "$key" || "$key" == \#* ]] && continue
                if grep -q "^${key}=" "$grub_default"; then
                    sed -i "s#^${key}=.*#${key}=${value}#" "$grub_default"
                else
                    echo "${key}=${value}" >> "$grub_default"
                fi
            done < <(grep -v '^#' "${ASSETS_DIR}/grub/frost-grub.cfg" | grep '=')
        fi
        success "/etc/default/grub updated with FROST theme settings"
    else
        warn "$grub_default not found — copying frost-grub.cfg's settings as a fresh file"
        run cp "${ASSETS_DIR}/grub/frost-grub.cfg" "$grub_default"
        CREATED_FILES+=("$grub_default")
    fi

    run chroot_exec "grub-mkconfig -o /boot/grub/grub.cfg"
    success "grub.cfg regenerated with the FROST theme"
}

# ─────────────────────────────────────────────────────────────────────────
# 5. PLYMOUTH SPLASH
# ─────────────────────────────────────────────────────────────────────────

install_plymouth() {
    step "Plymouth boot splash"
    if [[ "$SKIP_PLYMOUTH" == true ]]; then
        warn "Skipping Plymouth (--skip-plymouth)"; return 0
    fi

    ensure_chroot_network
    run chroot_exec "pacman -S --needed --noconfirm plymouth"

    local theme_dir="${ROOT_PREFIX}/usr/share/plymouth/themes/frost"
    run mkdir -p "${theme_dir}/frames"
    CREATED_DIRS+=("$theme_dir")
    run cp "${ASSETS_DIR}/plymouth/frost.plymouth" "$theme_dir/"
    run cp "${ASSETS_DIR}/plymouth/frost.script" "$theme_dir/"
    run cp "${ASSETS_DIR}/plymouth/background.png" "$theme_dir/"
    run cp "${ASSETS_DIR}/plymouth/lock.png" "$theme_dir/"
    run cp "${ASSETS_DIR}/plymouth/frames/"*.png "${theme_dir}/frames/"
    success "Plymouth theme files copied to ${theme_dir}"

    # Add the plymouth hook to mkinitcpio, right after udev (its documented
    # required position), then rebuild the initramfs.
    local mkinitcpio_conf="${ROOT_PREFIX}/etc/mkinitcpio.conf"
    if [[ -f "$mkinitcpio_conf" ]]; then
        if ! grep -qE '^HOOKS=.*\bplymouth\b' "$mkinitcpio_conf"; then
            local backup="${mkinitcpio_conf}.frost-bak-$(date +%s)"
            run cp -f "$mkinitcpio_conf" "$backup"
            BACKED_UP_FILES+=("${mkinitcpio_conf}|${backup}")
            run sed -i -E 's/(HOOKS=\([^)]*\budev\b)/\1 plymouth/' "$mkinitcpio_conf"
            success "Added 'plymouth' hook to mkinitcpio.conf"
        else
            log "'plymouth' hook already present in mkinitcpio.conf"
        fi
    else
        warn "$mkinitcpio_conf not found — skipping hook injection, add it manually"
    fi

    run chroot_exec "plymouth-set-default-theme frost"
    run chroot_exec "mkinitcpio -P"
    success "Plymouth set as default theme, initramfs rebuilt"
}

# ─────────────────────────────────────────────────────────────────────────
# 6. MOTD
# ─────────────────────────────────────────────────────────────────────────

install_motd() {
    step "MOTD"
    if [[ "$SKIP_MOTD" == true ]]; then
        warn "Skipping MOTD (--skip-motd)"; return 0
    fi

    local frost_etc="${ROOT_PREFIX}/etc/frost"
    run mkdir -p "$frost_etc"
    run cp "${ASSETS_DIR}/motd/motd.template" "${frost_etc}/motd.template"
    CREATED_FILES+=("${frost_etc}/motd.template")

    local conf="${frost_etc}/branding.conf"
    if [[ ! -f "$conf" ]]; then
        run cp "${ASSETS_DIR}/motd/branding.conf.example" "$conf"
        CREATED_FILES+=("$conf")
        if [[ -n "$TAGLINE" && "$DRY_RUN" != true ]]; then
            sed -i "s#^FROST_TAGLINE=.*#FROST_TAGLINE=\"${TAGLINE}\"#" "$conf"
        fi
    else
        log "branding.conf already exists, leaving your edits in place"
    fi

    local render_script="${ROOT_PREFIX}/opt/frost/bin/frost-motd-render.sh"
    run mkdir -p "$(dirname "$render_script")"
    run cp "${ASSETS_DIR}/motd/frost-motd-render.sh" "$render_script"
    run chmod +x "$render_script"
    CREATED_FILES+=("$render_script")

    run chroot_exec "/opt/frost/bin/frost-motd-render.sh"
    success "/etc/motd rendered (edit /etc/frost/branding.conf + re-run frost-motd-render.sh to change it)"
}

# ─────────────────────────────────────────────────────────────────────────
# 6.5. /etc/os-release — FROST's own distro identity
# ─────────────────────────────────────────────────────────────────────────

install_os_release() {
    step "/etc/os-release (FROST identity)"
    if [[ "$SKIP_OS_RELEASE" == true ]]; then
        warn "Skipping /etc/os-release (--skip-os-release)"; return 0
    fi

    # Found during real GNOME-session testing: with a stock Arch
    # /etc/os-release, GDM's login screen shows the Arch Linux logo as a
    # watermark (GNOME reads os-release's LOGO= field, which pacman's
    # base-files package sets to "archlinux-logo" and never anything
    # FROST-specific, since nothing before this wrote FROST's own
    # os-release). Clearing LOGO removes it — matches what was actually
    # asked for (no logo on the greeter at all, not a swap to FROST's
    # own logo there); Arch is credited instead via the standard
    # ID_LIKE=arch field, and PRETTY_NAME/HOME_URL identify FROST.
    local os_release="${ROOT_PREFIX}/etc/os-release"
    if [[ -f "$os_release" ]]; then
        local backup="${os_release}.frost-bak-$(date +%s)"
        run cp "$os_release" "$backup"
        BACKED_UP_FILES+=("${os_release}|${backup}")
    fi

    if [[ "$DRY_RUN" != true ]]; then
        cat > "$os_release" <<EOF
NAME="FROST"
PRETTY_NAME="FROST Linux"
ID=frost
ID_LIKE=arch
BUILD_ID=rolling
ANSI_COLOR="0;36"
LOGO=
HOME_URL="https://github.com/HigHollows/Frost"
DOCUMENTATION_URL="https://github.com/HigHollows/Frost#readme"
SUPPORT_URL="https://github.com/HigHollows/Frost/issues"
BUG_REPORT_URL="https://github.com/HigHollows/Frost/issues"
EOF
    fi
    success "/etc/os-release rewritten (FROST identity, ID_LIKE=arch, no login-screen logo)"
}

# ─────────────────────────────────────────────────────────────────────────
# 7. ZSH ALIASES
# ─────────────────────────────────────────────────────────────────────────

readonly MARK_BEGIN="# >>> FROST managed block — do not edit between markers >>>"
readonly MARK_END="# <<< FROST managed block <<<"

install_zsh() {
    step "zsh aliases"
    if [[ "$SKIP_ZSH" == true ]]; then
        warn "Skipping zsh aliases (--skip-zsh)"; return 0
    fi

    ensure_chroot_network
    run chroot_exec "pacman -S --needed --noconfirm zsh"

    local frost_etc="${ROOT_PREFIX}/etc/frost"
    run mkdir -p "$frost_etc"
    run cp "${ASSETS_DIR}/zsh/frost.zshrc" "${frost_etc}/frost.zshrc"
    CREATED_FILES+=("${frost_etc}/frost.zshrc")

    local sys_zshrc="${ROOT_PREFIX}/etc/zsh/zshrc"
    run mkdir -p "$(dirname "$sys_zshrc")"
    local is_new=false
    [[ -f "$sys_zshrc" ]] || is_new=true

    if [[ "$DRY_RUN" != true ]]; then
        if [[ "$is_new" == true ]]; then
            : > "$sys_zshrc"
            CREATED_FILES+=("$sys_zshrc")
        else
            local backup="${sys_zshrc}.frost-bak-$(date +%s)"
            cp -f "$sys_zshrc" "$backup"
            BACKED_UP_FILES+=("${sys_zshrc}|${backup}")
        fi
        grep -qF "$MARK_BEGIN" "$sys_zshrc" 2>/dev/null && \
            sed -i "/${MARK_BEGIN//\//\\/}/,/${MARK_END//\//\\/}/d" "$sys_zshrc"
        {
            echo "$MARK_BEGIN"
            echo "[[ -f /etc/frost/frost.zshrc ]] && source /etc/frost/frost.zshrc"
            echo "$MARK_END"
        } >> "$sys_zshrc"
    fi

    success "zsh installed, aliases wired into /etc/zsh/zshrc (system-wide, opt-in)"
    log "This does NOT change any user's default shell — frost-phase3.sh sets bash."
    log "To use it: chsh -s /usr/bin/zsh <username>"
}

# ─────────────────────────────────────────────────────────────────────────
# 8. MAIN
# ─────────────────────────────────────────────────────────────────────────

write_marker() {
    [[ "$DRY_RUN" == true ]] && return 0
    local marker="${ROOT_PREFIX}/opt/frost/state/branding.marker"
    mkdir -p "$(dirname "$marker")"
    cat > "$marker" <<EOF
name=boot-and-aesthetic
bootloader=${ACTIVE_BOOTLOADER}
grub_themed=$([[ "$SKIP_GRUB" != true && "$ACTIVE_BOOTLOADER" == "grub" ]] && echo true || echo false)
plymouth=$([[ "$SKIP_PLYMOUTH" != true ]] && echo true || echo false)
motd=$([[ "$SKIP_MOTD" != true ]] && echo true || echo false)
zsh=$([[ "$SKIP_ZSH" != true ]] && echo true || echo false)
completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
script_version=${SCRIPT_VERSION}
EOF
    CREATED_FILES+=("$marker")
}

main() {
    banner
    log "FROST branding install starting — log: $LOG_FILE"
    [[ "$DRY_RUN" == true ]] && warn "DRY-RUN MODE: no changes will be made."

    if [[ ! -d "$ASSETS_DIR" ]]; then
        error "Assets directory not found at ${ASSETS_DIR} — run this script from the FROST repo."
        exit 1
    fi

    check_root
    check_arch_linux
    detect_mode
    detect_bootloader

    install_grub_theme
    install_plymouth
    install_motd
    install_os_release
    install_zsh
    write_marker

    trap - ERR

    step "FROST branding complete"
    success "Bootloader   : ${ACTIVE_BOOTLOADER}"
    success "GRUB theme   : $([[ $SKIP_GRUB == true ]] && echo skipped || { [[ $ACTIVE_BOOTLOADER == grub ]] && echo applied || echo "n/a (not using grub)"; })"
    success "Plymouth     : $([[ $SKIP_PLYMOUTH == true ]] && echo skipped || echo applied)"
    success "MOTD         : $([[ $SKIP_MOTD == true ]] && echo skipped || echo applied)"
    success "os-release   : $([[ $SKIP_OS_RELEASE == true ]] && echo skipped || echo applied)"
    success "zsh aliases  : $([[ $SKIP_ZSH == true ]] && echo skipped || echo applied)"
    success "Log file     : ${LOG_FILE}"
    printf "\n%b❄  FROST looks like FROST now.%b\n\n" "${C_CYAN}${C_BOLD}" "${C_RESET}"
}

main "$@"
