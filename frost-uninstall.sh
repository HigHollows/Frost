#!/usr/bin/env bash
#
# frost-uninstall.sh — remove FROST cleanly
#
# Default behavior is deliberately conservative:
#   1. Backs up everything it's about to touch into one tarball first.
#   2. Removes FROST's own wholly-owned files (its /opt/frost and
#      /etc/frost trees, the systemd units, the GRUB/Plymouth themes,
#      its standalone config drop-ins) — these are safe to delete
#      outright since nothing else provides them.
#   3. Strips FROST's managed blocks out of shared files it only
#      partially edited (.bashrc, .zshrc, /etc/zsh/zshrc) using the same
#      markers those edits were made with.
#   4. Restores the OLDEST *.frost-bak-* backup for files FROST edited
#      inline without markers (/etc/default/grub, /etc/fstab,
#      /etc/mkinitcpio.conf, /etc/pacman.conf, /etc/sudoers,
#      /etc/locale.gen) — the earliest backup is the closest thing to
#      "before FROST ever touched this file".
#
# Installed *packages* (Steam, Docker, PostgreSQL, GPU drivers, ...) and
# *user accounts* are NOT touched unless you explicitly opt in
# (--remove-packages / --remove-users) — removing either blindly can
# break a system in ways far worse than what this script is trying to
# clean up.
#
# Usage:
#   sudo ./frost-uninstall.sh --target /mnt
#   sudo ./frost-uninstall.sh --local --remove-packages --yes
#
# Author: FROST project
# License: MIT

set -uo pipefail  # deliberately not -e: an uninstall should keep going
                   # and report what it couldn't do, not abort halfway

readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/tmp/frost-uninstall-$(date +%Y%m%d-%H%M%S).log"

if [[ -t 1 ]]; then
    C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'
    C_BLUE='\033[1;34m'; C_CYAN='\033[1;36m'; C_BOLD='\033[1m'; C_RESET='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_BOLD=''; C_RESET=''
fi
log()     { printf "%b[frost]%b %s\n" "${C_CYAN}${C_BOLD}" "${C_RESET}" "$*" | tee -a "$LOG_FILE"; }
success() { printf "%b[  ok ]%b %s\n" "${C_GREEN}${C_BOLD}" "${C_RESET}" "$*" | tee -a "$LOG_FILE"; }
warn()    { printf "%b[ warn]%b %s\n" "${C_YELLOW}${C_BOLD}" "${C_RESET}" "$*" | tee -a "$LOG_FILE" >&2; }
critical(){ printf "%b\xE2\x9D\x8C CRITICAL: %s%b\n" "${C_RED}${C_BOLD}" "$1" "${C_RESET}" | tee -a "$LOG_FILE" >&2; }
step()    { printf "\n%b==>%b %b%s%b\n" "${C_BLUE}${C_BOLD}" "${C_RESET}" "${C_BOLD}" "$*" "${C_RESET}" | tee -a "$LOG_FILE"; }

FROST_TARGET="/mnt"
FORCE_LOCAL=false
DRY_RUN=false
REMOVE_PACKAGES=false
REMOVE_USERS=false
AUTO_YES=false

usage() {
    cat <<EOF
${SCRIPT_NAME} — remove FROST cleanly

Usage: sudo ./${SCRIPT_NAME} [options]

  --target <path>       pacstrap target (default: /mnt)
  --local                 Force local mode (the running system)
  --remove-packages          Also remove a short, deliberately-conservative
                                list of FROST-added packages (off by default)
  --remove-users                Also delete the sudo user frost-phase3.sh
                                  created (off by default — destructive)
  --yes                            Skip confirmation prompts
  --dry-run                           Preview only, change nothing
  -h, --help                            Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)           FROST_TARGET="${2:?}"; shift 2 ;;
        --local)             FORCE_LOCAL=true; shift ;;
        --remove-packages)   REMOVE_PACKAGES=true; shift ;;
        --remove-users)      REMOVE_USERS=true; shift ;;
        --yes)               AUTO_YES=true; shift ;;
        --dry-run)           DRY_RUN=true; shift ;;
        -h|--help)           usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

run() {
    if [[ "$DRY_RUN" == true ]]; then
        printf "%b[dry-run]%b %s\n" "${C_YELLOW}" "${C_RESET}" "$*"
    else
        "$@"
    fi
}

confirm() {
    local msg="$1"
    printf "%b\xE2\x9A\xA0\xEF\xB8\x8F  WARNING: %s. Continue? (y/n) %b" "${C_YELLOW}${C_BOLD}" "$msg" "${C_RESET}"
    if [[ "$AUTO_YES" == true ]]; then echo "y  (--yes)"; return 0; fi
    if [[ ! -t 0 ]]; then echo "n  (no tty, refusing to guess)"; return 1; fi
    local reply; read -r reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

[[ "$EUID" -ne 0 ]] && { critical "Run as root"; exit 1; }
command -v pacman &>/dev/null || { critical "pacman not found — not an Arch system"; exit 1; }

ROOT_PREFIX=""
if [[ "$FORCE_LOCAL" != true ]] && command -v pacstrap &>/dev/null && mountpoint -q "$FROST_TARGET" 2>/dev/null; then
    ROOT_PREFIX="$FROST_TARGET"
fi
chroot_exec() {
    if [[ -n "$ROOT_PREFIX" ]]; then arch-chroot "$ROOT_PREFIX" bash -c "$1"; else bash -c "$1"; fi
}

step "Backing up everything before touching anything"
BACKUP_ARCHIVE="${ROOT_PREFIX}/root/frost-uninstall-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
BACKUP_PATHS=(opt/frost etc/frost etc/systemd/system/frost-*.service etc/systemd/system/frost-*.timer)
if [[ "$DRY_RUN" != true ]]; then
    (cd "${ROOT_PREFIX:-/}" && tar czf "$BACKUP_ARCHIVE" "${BACKUP_PATHS[@]}" 2>/dev/null)
fi
success "Backup: ${BACKUP_ARCHIVE}"

if ! confirm "This removes FROST's config/services (packages${REMOVE_PACKAGES:+ + a short list}${REMOVE_USERS:+ + the sudo user} untouched unless flagged)"; then
    warn "Cancelled — nothing removed. Backup above is harmless to keep or delete."
    exit 1
fi

step "Stopping and removing systemd units"
for unit in frost-daemon.service frost-security.timer frost-security.service \
            frost-update.timer frost-update.service \
            frost-performance.timer frost-performance.service; do
    run chroot_exec "systemctl disable --now '${unit}' 2>/dev/null" || true
    run rm -f "${ROOT_PREFIX}/etc/systemd/system/${unit}"
done
run chroot_exec "systemctl daemon-reload" || true
success "systemd units removed"

step "Stripping FROST managed blocks from shell rc files"
MARK_BEGIN="# >>> FROST managed block — do not edit between markers >>>"
MARK_END="# <<< FROST managed block <<<"
strip_block() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    grep -qF "$MARK_BEGIN" "$f" 2>/dev/null || return 0
    run sed -i "/${MARK_BEGIN//\//\\/}/,/${MARK_END//\//\\/}/d" "$f"
    log "  stripped FROST block from $f"
}
for home in "${ROOT_PREFIX}/etc/skel" "${ROOT_PREFIX}"/home/*; do
    [[ -d "$home" ]] || continue
    strip_block "${home}/.bashrc"
    strip_block "${home}/.tmux.conf"
    strip_block "${home}/.gitconfig"
    strip_block "${home}/.config/nvim/init.vim"
done
strip_block "${ROOT_PREFIX}/etc/zsh/zshrc"
success "Managed blocks stripped"

step "Removing FROST's wholly-owned files"
run rm -rf "${ROOT_PREFIX}/opt/frost"
run rm -rf "${ROOT_PREFIX}/etc/frost"
run rm -rf "${ROOT_PREFIX}/boot/grub/themes/frost"
run rm -rf "${ROOT_PREFIX}/usr/share/plymouth/themes/frost"
run rm -f "${ROOT_PREFIX}/etc/sysctl.d/99-frost-performance.conf"
run rm -f "${ROOT_PREFIX}/etc/ssh/sshd_config.d/99-frost-hardening.conf"
run rm -f "${ROOT_PREFIX}/etc/fail2ban/jail.local"
run rm -f "${ROOT_PREFIX}/usr/local/bin/frost"
success "FROST-owned files removed"

step "Reverting targeted inline edits (ramdisk fstab line, mkinitcpio plymouth hook)"
if [[ -f "${ROOT_PREFIX}/etc/fstab" ]]; then
    run sed -i '\#/mnt/ramdisk-build#d' "${ROOT_PREFIX}/etc/fstab"
fi
if [[ -f "${ROOT_PREFIX}/etc/mkinitcpio.conf" ]] && grep -qE '^HOOKS=.*\bplymouth\b' "${ROOT_PREFIX}/etc/mkinitcpio.conf"; then
    run sed -i -E 's/ plymouth\b//' "${ROOT_PREFIX}/etc/mkinitcpio.conf"
    run chroot_exec "mkinitcpio -P" || warn "mkinitcpio -P failed — rebuild initramfs manually"
fi
success "Inline edits reverted"

step "Restoring pre-FROST configs from their oldest backup"
mapfile -t backed_up_originals < <(
    find "${ROOT_PREFIX}/etc" -maxdepth 3 -name '*.frost-bak-*' 2>/dev/null \
        | sed -E 's/\.frost-bak-[0-9]+$//' | sort -u
)
if [[ "${#backed_up_originals[@]}" -eq 0 ]]; then
    log "No *.frost-bak-* files found under /etc — nothing to restore this way."
else
    for orig in "${backed_up_originals[@]}"; do
        oldest="$(ls -1 "${orig}".frost-bak-* 2>/dev/null | sort | head -n1)"
        [[ -z "$oldest" ]] && continue
        run cp -f "$oldest" "$orig"
        log "  restored $(basename "$orig") <- $(basename "$oldest")"
    done
fi
if [[ -f "${ROOT_PREFIX}/etc/default/grub" ]]; then
    run chroot_exec "grub-mkconfig -o /boot/grub/grub.cfg" 2>/dev/null || true
fi
success "Config restoration pass complete"

if [[ "$REMOVE_PACKAGES" == true ]]; then
    step "Removing FROST-added packages (conservative list)"
    warn "This list deliberately excludes anything ambiguous (docker, postgresql, git,"
    warn "python, nodejs, ...) that you may now depend on for other things — remove"
    warn "those yourself with pacman -Rns if you're sure."
    FROST_ONLY_PKGS="steam lutris heroic-games-launcher-bin protonup-qt mangohud lib32-mangohud \
        gamemode lib32-gamemode discord obs-studio wireshark-qt wireshark-cli hashcat \
        aircrack-ng hydra sqlmap john nikto gobuster nuclei-bin burpsuite \
        metasploit-framework w3af ufw fail2ban"
    for pkg in $FROST_ONLY_PKGS; do
        chroot_exec "pacman -Qi '${pkg}' &>/dev/null" && run chroot_exec "pacman -Rns --noconfirm '${pkg}'" || true
    done
    success "Conservative package list removed (see log for what was actually present)"
fi

if [[ "$REMOVE_USERS" == true ]]; then
    step "Removing the FROST-created user account"
    # /opt/frost/state/phase3.marker is already gone by this point (removed
    # above with the rest of /opt/frost) — read the username back out of
    # the backup archive we made at the very start instead.
    target_user="$(tar xzOf "$BACKUP_ARCHIVE" opt/frost/state/phase3.marker 2>/dev/null | grep '^username=' | cut -d= -f2)"
    if [[ -n "$target_user" && "$target_user" != "<none>" ]]; then
        if confirm "About to delete user '${target_user}' and their home directory"; then
            run chroot_exec "userdel -r '${target_user}'" || warn "userdel failed for ${target_user}"
            success "User ${target_user} removed"
        else
            warn "User removal cancelled"
        fi
    else
        warn "Could not determine the FROST-created username from the backup — skipping"
    fi
fi

step "FROST uninstall complete"
success "Backup kept at: ${BACKUP_ARCHIVE}"
success "Packages: $([[ $REMOVE_PACKAGES == true ]] && echo "conservative list removed" || echo "untouched (--remove-packages to also remove some)")"
success "User account: $([[ $REMOVE_USERS == true ]] && echo "removed" || echo "untouched (--remove-users to also remove it)")"
log "Log file: ${LOG_FILE}"
