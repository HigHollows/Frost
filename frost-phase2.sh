#!/usr/bin/env bash
#
# frost-phase2.sh — FROST Linux, Phase 2: AUR helper, dotfiles, frost-cli
#
# Builds on top of Phase 1 (frost-build.sh). Adds:
#   1. A trusted AUR helper (yay or paru), built from AUR *-bin sources by a
#      throwaway unprivileged build user — never as root.
#   2. FROST default dotfiles (bash, tmux, git, neovim) — idempotent,
#      managed-block based, deployed to /etc/skel and (optionally) a real user.
#   3. frost-cli — a small CLI at /opt/frost/bin/frost-cli, symlinked to
#      /usr/local/bin/frost.
#
# Usage:
#   sudo ./frost-phase2.sh [--target /mnt] [--local] [--helper yay|paru]
#                           [--user <username>] [--skip-aur] [--dry-run]
#
# See frost-phase2.README.md for full documentation.
#
# Author: FROST project
# License: MIT

set -euo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────
# 0. GLOBALS & OUTPUT (same conventions as frost-build.sh)
# ─────────────────────────────────────────────────────────────────────────

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="0.1.0-phase2"
readonly LOG_FILE="/tmp/frost-phase2-$(date +%Y%m%d-%H%M%S).log"

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
 ███████╗██████╗  ██████╗ ███████╗████████╗  ·  phase 2
 ██╔════╝██╔══██╗██╔═══██╗██╔════╝╚══██╔══╝
 █████╗  ██████╔╝██║   ██║███████╗   ██║      aur · dotfiles · frost-cli
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
BACKED_UP_FILES=()      # "orig|backup" pairs, restored on rollback
BUILD_USER_CREATED=false
SUDOERS_DROPIN=""

rollback() {
    local exit_code=$?
    error "Phase 2 failed (exit code $exit_code). Rolling back changes..."

    # Restore any dotfiles we clobbered
    for pair in "${BACKED_UP_FILES[@]:-}"; do
        [[ -z "$pair" ]] && continue
        local orig="${pair%%|*}" backup="${pair##*|}"
        if [[ -f "$backup" ]]; then
            cp -f "$backup" "$orig" 2>/dev/null && log "  restored $orig" || warn "  could not restore $orig"
        fi
    done

    # Remove files/dirs created this run (guarded to /opt/frost, /etc/skel, target home)
    for f in "${CREATED_FILES[@]:-}" "${CREATED_DIRS[@]:-}"; do
        [[ -z "$f" ]] && continue
        rm -rf "$f" 2>/dev/null && log "  removed $f" || true
    done

    cleanup_build_user "best-effort"

    error "Rollback complete. Full log at: $LOG_FILE"
    exit "$exit_code"
}

trap rollback ERR
trap 'error "Interrupted by user (SIGINT/SIGTERM)."; cleanup_build_user "best-effort"; exit 130' INT TERM

# ─────────────────────────────────────────────────────────────────────────
# 2. ARGUMENT PARSING
# ─────────────────────────────────────────────────────────────────────────

FROST_TARGET="/mnt"
FORCE_LOCAL=false
DRY_RUN=false
AUR_HELPER="yay"
TARGET_USER=""
SKIP_AUR=false

usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} — FROST build script (Phase 2)

Usage: sudo ./${SCRIPT_NAME} [options]

Options:
  --target <path>      pacstrap target from Phase 1 (default: /mnt, bootstrap mode only)
  --local               Force local mode (provision the running system)
  --helper <yay|paru>   AUR helper to install (default: yay)
  --user <name>         Real user to deploy dotfiles to (default: \$SUDO_USER if set)
  --skip-aur             Skip AUR helper build entirely
  --dry-run              Print what would happen, change nothing
  -h, --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)  FROST_TARGET="${2:?--target requires a path}"; shift 2 ;;
        --local)   FORCE_LOCAL=true; shift ;;
        --helper)  AUR_HELPER="${2:?--helper requires yay or paru}"; shift 2 ;;
        --user)    TARGET_USER="${2:?--user requires a username}"; shift 2 ;;
        --skip-aur) SKIP_AUR=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) error "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

if [[ "$AUR_HELPER" != "yay" && "$AUR_HELPER" != "paru" ]]; then
    error "--helper must be 'yay' or 'paru' (got: $AUR_HELPER)"
    exit 1
fi

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

ROOT_PREFIX=""   # "" for local mode, $FROST_TARGET for bootstrap mode

detect_mode() {
    if [[ "$FORCE_LOCAL" == true ]]; then
        BUILD_MODE="local"
    elif command -v pacstrap &>/dev/null && mountpoint -q "$FROST_TARGET" 2>/dev/null; then
        BUILD_MODE="bootstrap"
    else
        BUILD_MODE="local"
    fi

    if [[ "$BUILD_MODE" == "bootstrap" ]]; then
        ROOT_PREFIX="$FROST_TARGET"
    fi

    log "Build mode: ${C_BOLD}${BUILD_MODE}${C_RESET} (root prefix: '${ROOT_PREFIX:-/}')"
}

check_phase1() {
    local marker="${ROOT_PREFIX}/opt/frost/state/phase1.marker"
    if [[ ! -f "$marker" ]]; then
        warn "Phase 1 marker not found at $marker — has frost-build.sh run here?"
        warn "Continuing anyway, but /opt/frost/ structure may be incomplete."
    else
        success "Phase 1 detected ($(grep -c '' "$marker") lines in marker)"
    fi
}

# Run a command either directly (local mode) or inside the target chroot (bootstrap mode).
chroot_exec() {
    if [[ "$BUILD_MODE" == "bootstrap" ]]; then
        arch-chroot "$FROST_TARGET" bash -c "$1"
    else
        bash -c "$1"
    fi
}

ensure_chroot_network() {
    # arch-chroot needs working DNS to git-clone from the AUR. pacstrap does not
    # copy resolv.conf automatically, so we do it temporarily (regenerated by
    # NetworkManager on first real boot — this is not a permanent image change).
    [[ "$BUILD_MODE" != "bootstrap" ]] && return 0
    local resolv="${FROST_TARGET}/etc/resolv.conf"
    if [[ ! -s "$resolv" ]]; then
        log "Copying host /etc/resolv.conf into chroot for AUR network access"
        run cp -L /etc/resolv.conf "$resolv"
        CREATED_FILES+=("$resolv")
    fi
}

# ─────────────────────────────────────────────────────────────────────────
# 4. STEP 1 — TRUSTED AUR HELPER (built by a throwaway unprivileged user)
# ─────────────────────────────────────────────────────────────────────────

cleanup_build_user() {
    local mode="${1:-normal}"   # "normal" logs, "best-effort" stays quiet on failure
    [[ "$BUILD_USER_CREATED" != true ]] && return 0

    if [[ -n "$SUDOERS_DROPIN" ]]; then
        chroot_exec "rm -f '${SUDOERS_DROPIN}'" 2>/dev/null \
            && [[ "$mode" == normal ]] && log "Removed temporary sudoers drop-in"
    fi
    chroot_exec "userdel -r frostbuilder" 2>/dev/null \
        && [[ "$mode" == normal ]] && log "Removed temporary build user 'frostbuilder'"
    BUILD_USER_CREATED=false
}

install_aur_helper() {
    step "AUR helper (${AUR_HELPER})"

    if [[ "$SKIP_AUR" == true ]]; then
        warn "Skipping AUR helper install (--skip-aur)"
        return 0
    fi

    if chroot_exec "command -v ${AUR_HELPER} &>/dev/null"; then
        success "${AUR_HELPER} already installed, skipping"
        return 0
    fi

    log "Ensuring base-devel and git are present"
    run chroot_exec "pacman -S --needed --noconfirm base-devel git"

    ensure_chroot_network

    log "Creating throwaway build user 'frostbuilder' (never builds as root)"
    run chroot_exec "id -u frostbuilder &>/dev/null || useradd -m -G wheel frostbuilder"
    BUILD_USER_CREATED=true

    SUDOERS_DROPIN="/etc/sudoers.d/99-frost-builder"
    log "Granting frostbuilder passwordless sudo for pacman ONLY (scoped, temporary)"
    run chroot_exec "echo 'frostbuilder ALL=(ALL) NOPASSWD: /usr/bin/pacman' > '${SUDOERS_DROPIN}' && chmod 440 '${SUDOERS_DROPIN}'"

    local pkg="${AUR_HELPER}-bin"
    # Build inside frostbuilder's own $HOME, not /opt/frost/cache — that tree
    # is owned by root (Phase 1), so an unprivileged build user can't write
    # into it. /home/frostbuilder is created by useradd -m specifically so
    # it can.
    local build_dir="/home/frostbuilder/aur-build-${AUR_HELPER}"
    log "Building ${pkg} from AUR as frostbuilder"
    run chroot_exec "rm -rf '${build_dir}' && \
        sudo -u frostbuilder git clone --depth=1 https://aur.archlinux.org/${pkg}.git '${build_dir}' && \
        cd '${build_dir}' && sudo -u frostbuilder makepkg -si --noconfirm"

    log "Cleaning up build artifacts and throwaway user"
    run chroot_exec "rm -rf '${build_dir}'"
    cleanup_build_user "normal"

    if chroot_exec "command -v ${AUR_HELPER} &>/dev/null"; then
        success "${AUR_HELPER} installed successfully"
    else
        error "${AUR_HELPER} does not appear on PATH after install"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────
# 5. STEP 2 — FROST DEFAULT DOTFILES (idempotent, managed-block based)
# ─────────────────────────────────────────────────────────────────────────

readonly MARK_BEGIN="# >>> FROST managed block — do not edit between markers >>>"
readonly MARK_END="# <<< FROST managed block <<<"

# Appends (or replaces) a FROST managed block inside a file, backing up the
# original first. Safe to re-run — never duplicates the block.
write_managed_block() {
    local target_file="$1" block_content="$2"
    local dir; dir="$(dirname "$target_file")"
    [[ -d "$dir" ]] || { run mkdir -p "$dir"; CREATED_DIRS+=("$dir"); }

    if [[ -f "$target_file" ]]; then
        local backup="${target_file}.frost-bak-$(date +%s)"
        run cp -f "$target_file" "$backup"
        BACKED_UP_FILES+=("${target_file}|${backup}")
    else
        [[ -f "$target_file" ]] || CREATED_FILES+=("$target_file")
        run touch "$target_file"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log "(dry-run) would write FROST managed block into $target_file"
        return 0
    fi

    # Strip any previous FROST block, then append a fresh one.
    if grep -qF "$MARK_BEGIN" "$target_file" 2>/dev/null; then
        sed -i "/${MARK_BEGIN//\//\\/}/,/${MARK_END//\//\\/}/d" "$target_file"
    fi
    {
        echo "$MARK_BEGIN"
        echo "$block_content"
        echo "$MARK_END"
    } >> "$target_file"
}

deploy_dotfiles() {
    step "Deploying FROST default dotfiles"

    local skel="${ROOT_PREFIX}/etc/skel"
    run mkdir -p "$skel"

    # --- bash aliases & prompt tweaks ---
    write_managed_block "${skel}/.bashrc" "$(cat <<'EOF'
# FROST dev shortcuts
alias ll='ls -lah --color=auto'
alias gs='git status'
alias gl='git log --oneline --graph --decorate'
alias dco='docker compose'
alias dps='docker ps'
export EDITOR=nvim
export VISUAL=nvim
PS1='\[\033[1;36m\]\u@frost\[\033[0m\]:\[\033[1;34m\]\w\[\033[0m\]\$ '
EOF
)"

    # --- tmux ---
    write_managed_block "${skel}/.tmux.conf" "$(cat <<'EOF'
set -g mouse on
set -g history-limit 10000
set -g status-style bg=black,fg=cyan
set -g base-index 1
setw -g pane-base-index 1
EOF
)"

    # --- git ---
    write_managed_block "${skel}/.gitconfig" "$(cat <<'EOF'
[init]
	defaultBranch = main
[pull]
	rebase = false
[color]
	ui = auto
[alias]
	co = checkout
	st = status
	lg = log --oneline --graph --decorate
EOF
)"

    # --- neovim: minimal sane defaults, no plugin manager (Phase 1 spirit) ---
    local nvim_dir="${skel}/.config/nvim"
    run mkdir -p "$nvim_dir"
    CREATED_DIRS+=("$nvim_dir")
    write_managed_block "${nvim_dir}/init.vim" "$(cat <<'EOF'
set number relativenumber
set expandtab shiftwidth=2 tabstop=2
set ignorecase smartcase
set clipboard=unnamedplus
syntax on
EOF
)"

    success "Dotfiles written to ${skel} (applies to future new users)"

    # Optionally also apply to a real, already-existing user.
    local user="${TARGET_USER:-${SUDO_USER:-}}"
    if [[ "$BUILD_MODE" == "local" && -n "$user" && "$user" != "root" ]]; then
        local home; home="$(chroot_exec "getent passwd '${user}'" | cut -d: -f6 || true)"
        if [[ -n "$home" && -d "$home" ]]; then
            log "Applying dotfiles to existing user '${user}' (${home})"
            run cp -rT "$skel" "$home"
            run chown -R "${user}:${user}" "$home/.bashrc" "$home/.tmux.conf" "$home/.gitconfig" "$home/.config/nvim" 2>/dev/null || true
            success "Dotfiles applied to ${user}"
        else
            warn "Could not resolve home directory for user '${user}', skipping direct apply"
        fi
    else
        log "No existing target user to apply dotfiles to directly (use --user <name> or run via sudo)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────
# 6. STEP 3 — frost-cli
# ─────────────────────────────────────────────────────────────────────────

install_frost_cli() {
    step "Installing frost-cli"

    local bin_dir="${ROOT_PREFIX}/opt/frost/bin"
    run mkdir -p "$bin_dir"
    local cli_path="${bin_dir}/frost-cli"
    local is_new=true
    [[ -f "$cli_path" ]] && is_new=false

    if [[ "$DRY_RUN" != true ]]; then
        cat > "$cli_path" <<'FROST_CLI_EOF'
#!/usr/bin/env bash
# frost-cli — FROST distro helper CLI. Installed by frost-phase2.sh.
set -euo pipefail

FROST_ROOT="/opt/frost"
VERSION="0.1.0"

c_green='\033[1;32m'; c_red='\033[1;31m'; c_yellow='\033[1;33m'; c_reset='\033[0m'

cmd_status() {
    echo "FROST build state:"
    for marker in "${FROST_ROOT}"/state/*.marker; do
        [[ -f "$marker" ]] || continue
        echo "--- $(basename "$marker") ---"
        sed 's/^/  /' "$marker"
    done
}

cmd_doctor() {
    local ok=true
    printf "Disk space under %s:\n" "$FROST_ROOT"
    df -h "$FROST_ROOT" 2>/dev/null | sed 's/^/  /' || echo "  (unavailable)"

    if command -v docker &>/dev/null; then
        if systemctl is-active --quiet docker 2>/dev/null; then
            printf "  %bdocker: running%b\n" "$c_green" "$c_reset"
        else
            printf "  %bdocker: installed but not running%b\n" "$c_yellow" "$c_reset"
        fi
    else
        printf "  %bdocker: not installed%b\n" "$c_red" "$c_reset"; ok=false
    fi

    if command -v yay &>/dev/null || command -v paru &>/dev/null; then
        printf "  %baur helper: present%b\n" "$c_green" "$c_reset"
    else
        printf "  %baur helper: missing%b\n" "$c_yellow" "$c_reset"
    fi

    $ok
}

cmd_update() {
    echo "Updating official packages..."
    sudo pacman -Syu
    if command -v yay &>/dev/null; then
        echo "Updating AUR packages (yay)..."
        yay -Syu
    elif command -v paru &>/dev/null; then
        echo "Updating AUR packages (paru)..."
        paru -Syu
    fi
}

case "${1:-help}" in
    status)  cmd_status ;;
    doctor)  cmd_doctor ;;
    update)  cmd_update ;;
    version) echo "frost-cli ${VERSION}" ;;
    help|*)
        cat <<EOF
frost-cli ${VERSION} — FROST distro helper

Usage: frost <command>

Commands:
  status    Show completed FROST build phases
  doctor    Basic health check (disk, docker, aur helper)
  update    Update official + AUR packages
  version   Print frost-cli version
EOF
        ;;
esac
FROST_CLI_EOF
        chmod 755 "$cli_path"
    fi
    $is_new && CREATED_FILES+=("$cli_path")

    local link_dir="${ROOT_PREFIX}/usr/local/bin"
    run mkdir -p "$link_dir"
    local link_path="${link_dir}/frost"
    if [[ ! -e "$link_path" ]]; then
        run ln -s /opt/frost/bin/frost-cli "$link_path"
        CREATED_FILES+=("$link_path")
    fi

    success "frost-cli installed → ${link_path} -> /opt/frost/bin/frost-cli"

    local marker="${ROOT_PREFIX}/opt/frost/state/phase2.marker"
    if [[ "$DRY_RUN" != true ]]; then
        cat > "$marker" <<EOF
phase=2
name=aur-dotfiles-cli
aur_helper=${AUR_HELPER}
skip_aur=${SKIP_AUR}
completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
script_version=${SCRIPT_VERSION}
EOF
        CREATED_FILES+=("$marker")
    fi
}

# ─────────────────────────────────────────────────────────────────────────
# 7. MAIN
# ─────────────────────────────────────────────────────────────────────────

main() {
    banner
    log "FROST Phase 2 starting — log: $LOG_FILE"
    [[ "$DRY_RUN" == true ]] && warn "DRY-RUN MODE: no changes will be made."

    check_root
    check_arch_linux
    detect_mode
    check_phase1
    install_aur_helper
    deploy_dotfiles
    install_frost_cli

    trap - ERR

    step "FROST Phase 2 complete"
    success "AUR helper : ${AUR_HELPER}$([[ $SKIP_AUR == true ]] && echo ' (skipped)')"
    success "Dotfiles   : deployed to /etc/skel (+ target user if resolved)"
    success "frost-cli  : /opt/frost/bin/frost-cli (run: frost help)"
    success "Log file   : ${LOG_FILE}"
    printf "\n%b🧊 FROST Phase 2 done. Try: frost doctor%b\n\n" "${C_CYAN}${C_BOLD}" "${C_RESET}"
}

main "$@"
