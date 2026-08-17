#!/usr/bin/env bash
#
# frost-phase3.sh — FROST Linux, Phase 3: users, profiles, ISO packaging
#
# Builds on Phase 1 (frost-build.sh) + Phase 2 (frost-phase2.sh). Adds:
#   1. System finalization (bootstrap mode only): hostname, locale, timezone,
#      fstab, bootloader (systemd-boot on UEFI / grub on BIOS).
#   2. A standard sudo-capable user account (password read interactively,
#      never passed as a CLI argument or logged).
#   3. Optional profiles: "desktop" (Xorg + i3 + lightdm) or "server"
#      (openssh + ufw + fail2ban).
#   4. An archiso profile for a bootable FROST live ISO — official-repo
#      packages only (AUR stays a post-install step, as in Phase 2), with
#      the FROST scripts themselves baked in so the ISO can install itself.
#
# Usage:
#   sudo ./frost-phase3.sh --target /mnt --username tristan \
#        --hostname frost --profile desktop
#
# See frost-phase3.README.md for full documentation.
#
# Author: FROST project
# License: MIT

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_VERSION="0.1.0-phase3"
readonly LOG_FILE="/tmp/frost-phase3-$(date +%Y%m%d-%H%M%S).log"

# ─────────────────────────────────────────────────────────────────────────
# 0. OUTPUT (same conventions as frost-build.sh / frost-phase2.sh)
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
 ███████╗██████╗  ██████╗ ███████╗████████╗  ·  phase 3
 ██╔════╝██╔══██╗██╔═══██╗██╔════╝╚══██╔══╝
 █████╗  ██████╔╝██║   ██║███████╗   ██║      users · profiles · iso
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
BACKED_UP_FILES=()   # "orig|backup" pairs
CREATED_USER=""

rollback() {
    local exit_code=$?
    error "Phase 3 failed (exit code $exit_code). Rolling back changes..."

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

    if [[ -n "$CREATED_USER" ]]; then
        warn "Removing user account created this run: ${CREATED_USER}"
        chroot_exec "userdel -r '${CREATED_USER}'" 2>/dev/null || warn "  could not remove ${CREATED_USER}, check manually"
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

USERNAME=""
FULLNAME=""
SKIP_USER=false
SKIP_ROOT_PASSWORD=false
LOCK_ROOT=false

FROST_HOSTNAME="frost"
FROST_LOCALE="en_US.UTF-8"
FROST_TIMEZONE="UTC"

BOOTLOADER_KIND="systemd-boot"
PROFILE="none"

ISO_PROFILE_DIR="/opt/frost/iso/frost-releng"
ISO_OUT_DIR="/opt/frost/iso/out"
BUILD_ISO=false
SKIP_ISO=false

usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} — FROST build script (Phase 3)

Usage: sudo ./${SCRIPT_NAME} [options]

System (bootstrap mode only):
  --target <path>        pacstrap target from Phase 1 (default: /mnt)
  --local                  Force local mode (skips hostname/locale/fstab/bootloader)
  --hostname <name>        default: frost
  --locale <locale>        default: en_US.UTF-8
  --timezone <Region/City>  default: UTC
  --bootloader <kind>       systemd-boot | grub | none  (default: systemd-boot, auto per firmware)

User account:
  --username <name>        create this sudo-capable user (password prompted interactively)
  --fullname <"Name">       GECOS comment for the user
  --skip-user                Don't create/touch any user account
  --skip-root-password        Don't prompt for a root password
  --lock-root                  Lock root login instead of prompting (passwd -l root)

Profile:
  --profile <kind>          desktop | server | none  (default: none)

ISO packaging:
  --iso-profile <dir>       default: /opt/frost/iso/frost-releng
  --iso-out <dir>            default: /opt/frost/iso/out
  --build-iso                  Actually run mkarchiso (slow, needs several GB free)
  --skip-iso                   Skip ISO profile generation entirely

  --dry-run                    Print what would happen, change nothing
  -h, --help                    Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)           FROST_TARGET="${2:?}"; shift 2 ;;
        --local)             FORCE_LOCAL=true; shift ;;
        --hostname)          FROST_HOSTNAME="${2:?}"; shift 2 ;;
        --locale)            FROST_LOCALE="${2:?}"; shift 2 ;;
        --timezone)          FROST_TIMEZONE="${2:?}"; shift 2 ;;
        --bootloader)        BOOTLOADER_KIND="${2:?}"; shift 2 ;;
        --username)          USERNAME="${2:?}"; shift 2 ;;
        --fullname)          FULLNAME="${2:?}"; shift 2 ;;
        --skip-user)         SKIP_USER=true; shift ;;
        --skip-root-password) SKIP_ROOT_PASSWORD=true; shift ;;
        --lock-root)         LOCK_ROOT=true; shift ;;
        --profile)           PROFILE="${2:?}"; shift 2 ;;
        --iso-profile)       ISO_PROFILE_DIR="${2:?}"; shift 2 ;;
        --iso-out)           ISO_OUT_DIR="${2:?}"; shift 2 ;;
        --build-iso)         BUILD_ISO=true; shift ;;
        --skip-iso)           SKIP_ISO=true; shift ;;
        --dry-run)            DRY_RUN=true; shift ;;
        -h|--help)             usage; exit 0 ;;
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
# 3. INPUT VALIDATION (defense in depth — these values get interpolated
#    into chroot_exec's `bash -c "..."` strings, so allowlist them strictly)
# ─────────────────────────────────────────────────────────────────────────

validate_token() {
    local val="$1" pattern="$2" label="$3"
    if [[ ! "$val" =~ $pattern ]]; then
        error "Invalid ${label}: '${val}'"
        exit 1
    fi
}

validate_inputs() {
    [[ -n "$USERNAME" ]] && validate_token "$USERNAME" '^[a-z_][a-z0-9_-]{0,31}$' "--username"
    validate_token "$FROST_HOSTNAME" '^[a-zA-Z0-9-]{1,63}$' "--hostname"
    validate_token "$FROST_LOCALE" '^[A-Za-z0-9_.@-]+$' "--locale"
    validate_token "$FROST_TIMEZONE" '^[A-Za-z0-9_+/-]+$' "--timezone"
    validate_token "$BOOTLOADER_KIND" '^(systemd-boot|grub|none)$' "--bootloader"
    validate_token "$PROFILE" '^(desktop|server|none)$' "--profile"
    # Defensively strip shell-metacharacters from free-text GECOS field.
    FULLNAME="${FULLNAME//[\"\'\\\$\`]/}"

    if [[ ! -f "/usr/share/zoneinfo/${FROST_TIMEZONE}" ]]; then
        error "Unknown timezone '${FROST_TIMEZONE}' (no /usr/share/zoneinfo/${FROST_TIMEZONE} on this host)"
        error "Example: --timezone Europe/Paris"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────
# 4. PRE-FLIGHT
# ─────────────────────────────────────────────────────────────────────────

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error "This script must be run as root."
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

check_previous_phases() {
    for marker in phase1 phase2; do
        local f="${ROOT_PREFIX}/opt/frost/state/${marker}.marker"
        [[ -f "$f" ]] && success "${marker} detected" || warn "${marker} marker not found at $f — continuing anyway"
    done
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

# ─────────────────────────────────────────────────────────────────────────
# 5. SYSTEM FINALIZATION (bootstrap mode only)
# ─────────────────────────────────────────────────────────────────────────

set_hostname() {
    step "Setting hostname"
    if [[ "$BUILD_MODE" != "bootstrap" ]]; then
        warn "Local mode: not touching the running system's hostname. Skipping."
        return 0
    fi
    local hn_file="${FROST_TARGET}/etc/hostname"
    local hosts_file="${FROST_TARGET}/etc/hosts"
    [[ -f "$hn_file" ]] || CREATED_FILES+=("$hn_file")
    [[ -f "$hosts_file" ]] || CREATED_FILES+=("$hosts_file")

    if [[ "$DRY_RUN" != true ]]; then
        echo "$FROST_HOSTNAME" > "$hn_file"
        cat > "$hosts_file" <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${FROST_HOSTNAME}.localdomain ${FROST_HOSTNAME}
EOF
    fi
    success "Hostname set to '${FROST_HOSTNAME}'"
}

set_locale_and_timezone() {
    step "Setting locale (${FROST_LOCALE}) and timezone (${FROST_TIMEZONE})"
    if [[ "$BUILD_MODE" != "bootstrap" ]]; then
        warn "Local mode: not touching the running system's locale/timezone. Skipping."
        return 0
    fi

    local locale_gen="${FROST_TARGET}/etc/locale.gen"
    if [[ -f "$locale_gen" ]]; then
        local backup="${locale_gen}.frost-bak-$(date +%s)"
        run cp -f "$locale_gen" "$backup"
        BACKED_UP_FILES+=("${locale_gen}|${backup}")
        run sed -i "s/^#${FROST_LOCALE}/${FROST_LOCALE}/" "$locale_gen"
        if ! grep -q "^${FROST_LOCALE}" "$locale_gen" 2>/dev/null && [[ "$DRY_RUN" != true ]]; then
            echo "${FROST_LOCALE} UTF-8" >> "$locale_gen"
        fi
    fi
    run chroot_exec "locale-gen"
    if [[ "$DRY_RUN" != true ]]; then
        echo "LANG=${FROST_LOCALE}" > "${FROST_TARGET}/etc/locale.conf"
        CREATED_FILES+=("${FROST_TARGET}/etc/locale.conf")
    fi

    run chroot_exec "ln -sf '/usr/share/zoneinfo/${FROST_TIMEZONE}' /etc/localtime"
    chroot_exec "hwclock --systohc" || warn "hwclock --systohc failed (no RTC access in this environment?) — non-fatal"

    success "Locale and timezone configured"
}

generate_fstab() {
    step "Generating fstab"
    if [[ "$BUILD_MODE" != "bootstrap" ]]; then
        warn "Local mode: fstab generation only applies in bootstrap mode. Skipping."
        return 0
    fi
    if ! command -v genfstab &>/dev/null; then
        error "genfstab not found (arch-install-scripts package missing on this live environment)"
        exit 1
    fi

    local fstab="${FROST_TARGET}/etc/fstab"
    if [[ -f "$fstab" && -s "$fstab" ]]; then
        local backup="${fstab}.frost-bak-$(date +%s)"
        run cp -f "$fstab" "$backup"
        BACKED_UP_FILES+=("${fstab}|${backup}")
    else
        CREATED_FILES+=("$fstab")
    fi

    if [[ "$DRY_RUN" != true ]]; then
        genfstab -U "$FROST_TARGET" > "$fstab"
    fi
    success "fstab written to ${fstab}"
}

install_bootloader() {
    step "Bootloader (${BOOTLOADER_KIND})"
    if [[ "$BUILD_MODE" != "bootstrap" ]]; then
        warn "Local mode: bootloader install only applies in bootstrap mode. Skipping."
        return 0
    fi
    if [[ "$BOOTLOADER_KIND" == "none" ]]; then
        warn "Bootloader install skipped (--bootloader none)."
        warn "System will NOT be bootable until a bootloader is installed manually."
        return 0
    fi

    ensure_chroot_network

    local root_dev
    root_dev="$(findmnt -no SOURCE "$FROST_TARGET" 2>/dev/null || true)"
    if [[ -z "$root_dev" ]]; then
        error "Could not determine the root device backing ${FROST_TARGET} (is it mounted?)"
        exit 1
    fi
    local root_partuuid
    root_partuuid="$(blkid -s PARTUUID -o value "$root_dev" 2>/dev/null || true)"

    if [[ -d /sys/firmware/efi/efivars ]]; then
        log "UEFI firmware detected on this host"
        [[ "$BOOTLOADER_KIND" != "systemd-boot" ]] && warn "UEFI detected but --bootloader=${BOOTLOADER_KIND}; systemd-boot is the recommended default anyway, proceeding with it."

        local esp=""
        for candidate in "${FROST_TARGET}/boot" "${FROST_TARGET}/efi"; do
            mountpoint -q "$candidate" 2>/dev/null && { esp="$candidate"; break; }
        done
        if [[ -z "$esp" ]]; then
            error "No EFI System Partition mounted at ${FROST_TARGET}/boot or ${FROST_TARGET}/efi."
            error "Mount your ESP there first (e.g. mount /dev/sda1 ${FROST_TARGET}/boot), then re-run."
            return 1
        fi
        local esp_rel="${esp#"$FROST_TARGET"}"
        [[ -z "$esp_rel" ]] && esp_rel="/boot"

        run chroot_exec "bootctl --esp-path='${esp_rel}' install"

        if [[ "$DRY_RUN" != true ]]; then
            local loader_dir="${esp}/loader"
            mkdir -p "${loader_dir}/entries"
            cat > "${loader_dir}/loader.conf" <<EOF
default frost.conf
timeout 3
console-mode max
editor no
EOF
            cat > "${loader_dir}/entries/frost.conf" <<EOF
title   FROST Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=PARTUUID=${root_partuuid} rw quiet
EOF
            CREATED_FILES+=("${loader_dir}/loader.conf" "${loader_dir}/entries/frost.conf")
        fi
        success "systemd-boot installed (root=PARTUUID=${root_partuuid:-<unknown, check manually>})"
    else
        log "BIOS/legacy firmware detected on this host"
        [[ "$BOOTLOADER_KIND" != "grub" ]] && warn "BIOS detected: grub is the only supported option here, proceeding with it."

        local pk_name disk
        pk_name="$(lsblk -no PKNAME "$root_dev" 2>/dev/null || true)"
        if [[ -z "$pk_name" ]]; then
            error "Could not determine the parent disk of ${root_dev} for grub-install."
            return 1
        fi
        disk="/dev/${pk_name}"

        run chroot_exec "pacman -S --needed --noconfirm grub"
        run chroot_exec "grub-install --target=i386-pc '${disk}'"
        run chroot_exec "grub-mkconfig -o /boot/grub/grub.cfg"
        success "grub installed to ${disk}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────
# 6. USER ACCOUNT
# ─────────────────────────────────────────────────────────────────────────

configure_sudo_wheel() {
    step "Enabling sudo for the 'wheel' group"
    local sudoers="${ROOT_PREFIX}/etc/sudoers"
    if [[ ! -f "$sudoers" ]]; then
        error "sudoers file not found at ${sudoers}"
        exit 1
    fi
    if grep -qE '^%wheel[[:space:]]+ALL=\(ALL(:ALL)?\)[[:space:]]+ALL' "$sudoers"; then
        log "wheel sudo rule already enabled"
        return 0
    fi

    local backup="${sudoers}.frost-bak-$(date +%s)"
    run cp -f "$sudoers" "$backup"
    BACKED_UP_FILES+=("${sudoers}|${backup}")

    if [[ "$DRY_RUN" != true ]]; then
        sed -i \
            -e 's/^# *%wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' \
            -e 's/^# *%wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' \
            "$sudoers"
        if ! visudo -c -f "$sudoers" &>/dev/null; then
            error "sudoers edit produced invalid syntax — restoring backup immediately"
            cp -f "$backup" "$sudoers"
            exit 1
        fi
    fi
    success "wheel group can now use sudo"
}

set_password_for() {
    local user="$1"
    if [[ "$DRY_RUN" == true ]]; then
        log "(dry-run) would prompt for a password for '${user}'"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        warn "No interactive terminal available — locking '${user}' instead of setting a password."
        warn "Set it later with: passwd ${user}"
        chroot_exec "passwd -l '${user}'" || true
        return 0
    fi

    local pass1 pass2
    while true; do
        read -rs -p "Password for ${user}: " pass1; echo
        read -rs -p "Confirm password: " pass2; echo
        if [[ -z "$pass1" ]]; then
            warn "Password cannot be empty, try again."
        elif [[ "$pass1" != "$pass2" ]]; then
            warn "Passwords did not match, try again."
        else
            break
        fi
    done

    if [[ "$BUILD_MODE" == "bootstrap" ]]; then
        printf '%s:%s\n' "$user" "$pass1" | arch-chroot "$FROST_TARGET" chpasswd
    else
        printf '%s:%s\n' "$user" "$pass1" | chpasswd
    fi
    unset pass1 pass2
    success "Password set for '${user}'"
}

create_user() {
    step "Standard user account"
    if [[ "$SKIP_USER" == true || -z "$USERNAME" ]]; then
        warn "No --username given (or --skip-user set) — skipping user creation."
        return 0
    fi

    if chroot_exec "id -u '${USERNAME}' &>/dev/null"; then
        warn "User '${USERNAME}' already exists — will still ensure group membership."
    else
        log "Creating user '${USERNAME}'${FULLNAME:+ (${FULLNAME})}"
        run chroot_exec "useradd -m -G wheel,docker -c '${FULLNAME}' -s /bin/bash '${USERNAME}'"
        CREATED_USER="$USERNAME"
    fi
    run chroot_exec "usermod -aG wheel,docker '${USERNAME}'"

    configure_sudo_wheel
    set_password_for "$USERNAME"

    if [[ "$LOCK_ROOT" == true ]]; then
        log "Locking root login (--lock-root)"
        run chroot_exec "passwd -l root"
    elif [[ "$SKIP_ROOT_PASSWORD" != true ]]; then
        log "Setting a root password too (use --skip-root-password or --lock-root to change this)"
        set_password_for "root"
    fi

    success "User '${USERNAME}' ready (groups: wheel, docker)"
}

# ─────────────────────────────────────────────────────────────────────────
# 7. OPTIONAL PROFILES
# ─────────────────────────────────────────────────────────────────────────

install_profile() {
    step "Profile: ${PROFILE}"
    ensure_chroot_network

    case "$PROFILE" in
        none)
            log "No profile requested (--profile none)."
            ;;
        desktop)
            # NOTE: plain space-separated strings, not arrays — chroot_exec
            # takes a single shell-command string, and "${arr[*]}" joins on
            # the FIRST CHARACTER OF $IFS, which this script sets to
            # newline/tab at the top. An array join here would silently
            # turn "pacman -S pkg1 pkg2 pkg3" into three separate commands.
            local pkgs="xorg-server xorg-xinit i3-wm i3status dmenu alacritty picom feh lightdm lightdm-gtk-greeter pipewire pipewire-pulse wireplumber ttf-dejavu"
            log "Installing desktop profile: ${pkgs}"
            run chroot_exec "pacman -S --needed --noconfirm ${pkgs}"
            run chroot_exec "systemctl enable lightdm.service"
            success "Desktop profile installed (i3 + lightdm)"
            ;;
        server)
            local pkgs="openssh ufw fail2ban"
            log "Installing server profile: ${pkgs}"
            run chroot_exec "pacman -S --needed --noconfirm ${pkgs}"
            run chroot_exec "systemctl enable sshd.service"
            run chroot_exec "systemctl enable ufw.service"
            if [[ "$DRY_RUN" != true ]]; then
                # Best-effort: writes persistent /etc/ufw rule files even if the
                # live netfilter apply is a no-op inside a chroot; ufw.service
                # applies them for real on first boot.
                chroot_exec "ufw default deny incoming" || true
                chroot_exec "ufw default allow outgoing" || true
                chroot_exec "ufw allow ssh" || true
            fi
            success "Server profile installed (openssh + ufw + fail2ban)"
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────
# 8. ARCHISO PACKAGING
# ─────────────────────────────────────────────────────────────────────────

generate_iso_profile() {
    step "archiso profile"
    if [[ "$SKIP_ISO" == true ]]; then
        warn "Skipping ISO profile generation (--skip-iso)."
        return 0
    fi

    if ! command -v mkarchiso &>/dev/null; then
        log "Installing archiso on this host (needed to prepare/build the profile)"
        # This runs on the live-boot host itself, not inside the target
        # chroot — its package databases are per-session and may still be
        # empty (e.g. after a fresh boot that never ran pacman -Sy), unlike
        # the target's, which Phase 1 already synced and persisted to disk.
        run pacman -Sy --noconfirm
        run pacman -S --needed --noconfirm archiso
    fi

    local base_profile="/usr/share/archiso/configs/releng"
    if [[ ! -d "$base_profile" ]]; then
        error "Base archiso profile not found at ${base_profile} (archiso package missing/broken?)"
        exit 1
    fi

    if [[ -d "$ISO_PROFILE_DIR" ]]; then
        warn "ISO profile dir already exists at ${ISO_PROFILE_DIR} — regenerating from scratch."
        run rm -rf "$ISO_PROFILE_DIR"
    fi
    run mkdir -p "$(dirname "$ISO_PROFILE_DIR")"
    run cp -r "$base_profile" "$ISO_PROFILE_DIR"
    CREATED_DIRS+=("$ISO_PROFILE_DIR")

    if [[ "$DRY_RUN" != true ]]; then
        # --- branding ---
        sed -i \
            -e 's/^iso_name=.*/iso_name="frost"/' \
            -e "s/^iso_label=.*/iso_label=\"FROST_$(date +%Y%m)\"/" \
            -e 's#^iso_publisher=.*#iso_publisher="FROST Project"#' \
            -e 's/^iso_application=.*/iso_application="FROST Linux Live\/Rescue"/' \
            -e 's/^install_dir=.*/install_dir="frost"/' \
            "${ISO_PROFILE_DIR}/profiledef.sh"

        # --- extra packages baked into the live ISO (official repos only) ---
        cat >> "${ISO_PROFILE_DIR}/packages.x86_64" <<'EOF'
git
tmux
neovim
htop
python
python-pip
docker
docker-compose
nodejs
npm
EOF

        # --- carry the FROST installer scripts onto the live ISO itself ---
        local overlay="${ISO_PROFILE_DIR}/airootfs/opt/frost/scripts"
        mkdir -p "$overlay"
        for f in frost-build.sh frost-phase2.sh frost-phase3.sh; do
            [[ -f "${SCRIPT_DIR}/${f}" ]] && cp "${SCRIPT_DIR}/${f}" "${overlay}/"
        done
        chmod +x "${overlay}"/*.sh 2>/dev/null || true

        mkdir -p "${ISO_PROFILE_DIR}/airootfs/etc"
        cat > "${ISO_PROFILE_DIR}/airootfs/etc/motd" <<'EOF'

  ███████╗██████╗  ██████╗ ███████╗████████╗
  ██╔════╝██╔══██╗██╔═══██╗██╔════╝╚══██╔══╝
  █████╗  ██████╔╝██║   ██║███████╗   ██║
  ██╔══╝  ██╔══██╗██║   ██║╚════██║   ██║
  ██║     ██║  ██║╚██████╔╝███████║   ██║
  ╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝

  Welcome to the FROST live environment.
  Installer scripts live in /opt/frost/scripts/ — start with frost-build.sh.

EOF
    fi

    success "archiso profile ready at ${ISO_PROFILE_DIR}"

    if [[ "$BUILD_ISO" == true ]]; then
        step "Building the ISO (mkarchiso) — this takes a while and several GB free"
        run mkdir -p "$ISO_OUT_DIR"
        run mkarchiso -v -w "${ISO_PROFILE_DIR}/work" -o "$ISO_OUT_DIR" "$ISO_PROFILE_DIR"
        success "ISO built in ${ISO_OUT_DIR}"
    else
        log "Profile generated only (--build-iso not set). To build it later:"
        log "  sudo mkarchiso -v -o ${ISO_OUT_DIR} ${ISO_PROFILE_DIR}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────
# 9. MAIN
# ─────────────────────────────────────────────────────────────────────────

write_marker() {
    local marker="${ROOT_PREFIX}/opt/frost/state/phase3.marker"
    [[ "$DRY_RUN" == true ]] && return 0
    mkdir -p "$(dirname "$marker")"
    cat > "$marker" <<EOF
phase=3
name=users-profiles-iso
hostname=${FROST_HOSTNAME}
locale=${FROST_LOCALE}
timezone=${FROST_TIMEZONE}
bootloader=${BOOTLOADER_KIND}
username=${USERNAME:-<none>}
profile=${PROFILE}
iso_profile_dir=${ISO_PROFILE_DIR}
build_iso=${BUILD_ISO}
completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
script_version=${SCRIPT_VERSION}
EOF
    CREATED_FILES+=("$marker")
}

main() {
    banner
    log "FROST Phase 3 starting — log: $LOG_FILE"
    [[ "$DRY_RUN" == true ]] && warn "DRY-RUN MODE: no changes will be made."

    check_root
    check_arch_linux
    validate_inputs
    detect_mode
    check_previous_phases

    set_hostname
    set_locale_and_timezone
    generate_fstab
    create_user
    install_bootloader
    install_profile
    generate_iso_profile
    write_marker

    trap - ERR

    step "FROST Phase 3 complete"
    success "Hostname   : ${FROST_HOSTNAME}"
    success "Locale/TZ  : ${FROST_LOCALE} / ${FROST_TIMEZONE}"
    success "Bootloader : ${BOOTLOADER_KIND}"
    success "User       : ${USERNAME:-<none created>}"
    success "Profile    : ${PROFILE}"
    success "ISO profile: ${ISO_PROFILE_DIR}$([[ $BUILD_ISO == true ]] && echo " (built -> ${ISO_OUT_DIR})" || echo " (not built, --build-iso to do so)")"
    success "Log file   : ${LOG_FILE}"
    printf "\n%b🧊 FROST is complete. Reboot into your new system, or build the ISO.%b\n\n" "${C_CYAN}${C_BOLD}" "${C_RESET}"
}

main "$@"
