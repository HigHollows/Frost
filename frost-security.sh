#!/usr/bin/env bash
#
# frost-security.sh — FROST Linux, Security & Hacking Tools pack
#
# Installs and configures a pentest/security-research toolkit on top of
# Phases 1-3: standard scanning/cracking/exploitation tools, a firewall
# baseline, optional VPN auto-connect, SSH hardening, and optional Tor
# integration.
#
# ⚠ AUTHORIZED USE ONLY. Every tool this script installs is dual-use.
# Only point them at systems/networks you own or have explicit written
# authorization to test (a pentest engagement, a CTF, your own lab).
# Unauthorized access or scanning is illegal in most jurisdictions —
# that's on you, not this script.
#
# Usage:
#   sudo ./frost-security.sh --target /mnt
#   sudo ./frost-security.sh --local --skip-vpn --enable-tor
#
# See SECURITY.README.md for the full tool list, quick-start commands,
# and what each config template expects from you before it's usable.
#
# Author: FROST project
# License: MIT

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ASSETS_DIR="${SCRIPT_DIR}/security"
readonly SCRIPT_VERSION="0.1.0-security"
readonly LOG_FILE="/tmp/frost-security-$(date +%Y%m%d-%H%M%S).log"

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

# Exact phrasing requested for tool install outcomes — kept distinct from
# the generic log/warn/error helpers above so these read as tool-status
# lines at a glance.
tool_missing()  { printf "%b[FATAL]%b ERROR: %s not found\n" "${C_RED}${C_BOLD}" "${C_RESET}" "$1" | tee -a "$LOG_FILE" >&2 ; }
tool_sudo()     { printf "%b[ warn]%b WARN: Sudo required for %s\n" "${C_YELLOW}${C_BOLD}" "${C_RESET}" "$1" | tee -a "$LOG_FILE" >&2 ; }
tool_success()  { printf "%b[  ok ]%b \xE2\x9C\x85 %s installed & configured\n" "${C_GREEN}${C_BOLD}" "${C_RESET}" "$1" | tee -a "$LOG_FILE" ; }

banner() {
    printf "%b" "${C_CYAN}${C_BOLD}"
    cat <<'EOF'
 ███████╗██████╗  ██████╗ ███████╗████████╗  ·  security & hacking tools
 ██╔════╝██╔══██╗██╔═══██╗██╔════╝╚══██╔══╝
 █████╗  ██████╔╝██║   ██║███████╗   ██║      nmap · metasploit · hashcat · ...
 ██╔══╝  ██╔══██╗██║   ██║╚════██║   ██║
 ██║     ██║  ██║╚██████╔╝███████║   ██║
 ╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝
EOF
    printf "%b\n" "${C_RESET}"
    printf "%b⚠  AUTHORIZED USE ONLY%b — pentest engagements, CTFs, your own lab.\n" "${C_YELLOW}${C_BOLD}" "${C_RESET}"
    printf "   Unauthorized scanning/access is illegal in most jurisdictions.\n\n"
}

# ─────────────────────────────────────────────────────────────────────────
# 1. STATE TRACKING & ERROR TRAP
# ─────────────────────────────────────────────────────────────────────────

CREATED_DIRS=()
CREATED_FILES=()
BACKED_UP_FILES=()

rollback() {
    local exit_code=$?
    error "Security setup failed (exit code $exit_code). Rolling back..."

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
SKIP_TOOLS=false
SKIP_FIREWALL=false
SKIP_VPN=false
SKIP_SSH_HARDENING=false
ENABLE_VPN_AUTOCONNECT=false
ENABLE_TOR=false
OVERRIDE_USER=""
OVERRIDE_AUR_HELPER=""

usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} — FROST Security & Hacking Tools pack

Usage: sudo ./${SCRIPT_NAME} [options]

  --target <path>            pacstrap target from Phase 1 (default: /mnt)
  --local                     Force local mode (provision the running system)
  --username <name>            Target user for AUR builds / SSH hardening
                                  (default: auto-detected from Phase 3 marker)
  --aur-helper <yay|paru>        Override AUR helper auto-detection
  --skip-tools                     Skip the tool installation step
  --skip-firewall                    Skip ufw setup
  --skip-vpn                          Skip WireGuard/OpenVPN template install
  --skip-ssh-hardening                  Skip SSH/fail2ban hardening
  --enable-vpn-autoconnect                 Enable the VPN unit IF its config
                                              has been filled in (no placeholders left)
  --enable-tor                              Install Tor + torbrowser-launcher (optional, off by default)
  --dry-run                                    Print what would happen, change nothing
  -h, --help                                    Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)               FROST_TARGET="${2:?}"; shift 2 ;;
        --local)                FORCE_LOCAL=true; shift ;;
        --username)             OVERRIDE_USER="${2:?}"; shift 2 ;;
        --aur-helper)           OVERRIDE_AUR_HELPER="${2:?}"; shift 2 ;;
        --skip-tools)           SKIP_TOOLS=true; shift ;;
        --skip-firewall)        SKIP_FIREWALL=true; shift ;;
        --skip-vpn)             SKIP_VPN=true; shift ;;
        --skip-ssh-hardening)   SKIP_SSH_HARDENING=true; shift ;;
        --enable-vpn-autoconnect) ENABLE_VPN_AUTOCONNECT=true; shift ;;
        --enable-tor)           ENABLE_TOR=true; shift ;;
        --dry-run)               DRY_RUN=true; shift ;;
        -h|--help)                usage; exit 0 ;;
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
    if [[ "$EUID" -ne 0 ]]; then
        tool_sudo "frost-security.sh"
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
        success "Target user for AUR builds / SSH hardening: ${TARGET_USER}"
    else
        warn "No usable non-root user found (checked Phase 3 marker + passwd). AUR-only tools"
        warn "and SSH hardening will be skipped — pass --username <name> to fix, or run"
        warn "frost-phase3.sh first to create one."
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
        warn "No AUR helper found (run frost-phase2.sh first). AUR-only tools will be skipped"
        warn "with manual install instructions instead."
    fi
}

# ─────────────────────────────────────────────────────────────────────────
# 4. TOOL INSTALL (official repo first, AUR fallback, never silent)
# ─────────────────────────────────────────────────────────────────────────

# install_tool <display name> <official candidates space-separated> <AUR candidates space-separated>
# Never lets a single missing/unavailable tool abort the whole script.
install_tool() {
    # Local IFS override: the script-wide IFS=$'\n\t' (set at the top,
    # for word-splitting safety elsewhere) would otherwise stop the
    # `for pkg in $official` loops below from splitting on spaces at
    # all — the exact class of bug documented in ARCHITECTURE.md's
    # "Lesson 2". Scoped to this function only.
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

install_security_tools() {
    step "Installing security tools"
    if [[ "$SKIP_TOOLS" == true ]]; then
        warn "Skipping tool installation (--skip-tools)"
        return 0
    fi
    ensure_chroot_network

    # name                        official repo candidates          AUR candidates
    install_tool "nmap"                        "nmap"                             ""                    || true
    install_tool "wireshark"                    "wireshark-qt wireshark-cli"        ""                    || true
    install_tool "hashcat"                        "hashcat"                          ""                    || true
    install_tool "aircrack-ng"                      "aircrack-ng"                      ""                    || true
    install_tool "hydra"                              "hydra"                            ""                    || true
    install_tool "sqlmap"                                "sqlmap"                           ""                    || true
    install_tool "john"                                     "john"                             "john"                || true
    install_tool "nikto"                                       "nikto"                            "nikto"               || true
    install_tool "gobuster"                                       "gobuster"                         "gobuster"            || true
    install_tool "nuclei"                                             "nuclei"                           "nuclei-bin nuclei"   || true
    install_tool "burp-suite-community"                                  ""                                 "burpsuite"           || true
    install_tool "metasploit-framework"                                      ""                                 "metasploit"          || true
    install_tool "w3af"                                                          ""                                 "w3af"                || true
    warn "w3af note: upstream is largely unmaintained (Python 2 era) — expect install/run"
    warn "issues on a current system. nuclei/nikto/gobuster cover most of the same ground"
    warn "and are actively maintained; see SECURITY.README.md."

    if [[ -n "$TARGET_USER" ]] && chroot_exec "command -v dumpcap &>/dev/null"; then
        log "Configuring passwordless packet capture for ${TARGET_USER} (wireshark group)"
        run chroot_exec "groupadd -f wireshark"
        run chroot_exec "usermod -aG wireshark '${TARGET_USER}'"
        run chroot_exec "setcap cap_net_raw,cap_net_admin=eip \$(command -v dumpcap)"
        success "dumpcap capability set — ${TARGET_USER} can capture packets without full root"
    fi
}

# ─────────────────────────────────────────────────────────────────────────
# 5. FIREWALL
# ─────────────────────────────────────────────────────────────────────────

configure_firewall() {
    step "Firewall (ufw)"
    if [[ "$SKIP_FIREWALL" == true ]]; then
        warn "Skipping firewall setup (--skip-firewall)"; return 0
    fi
    ensure_chroot_network
    run chroot_exec "pacman -S --needed --noconfirm ufw"
    run chroot_exec "systemctl enable ufw.service"

    if [[ "$DRY_RUN" != true ]]; then
        # Idempotent: ufw no-ops or warns (not errors) on an already-applied rule.
        chroot_exec "ufw default deny incoming" || true
        chroot_exec "ufw default allow outgoing" || true
        chroot_exec "ufw allow ssh" || true
        chroot_exec "ufw logging on" || true
    fi
    success "ufw configured (default deny incoming, allow outgoing + ssh)"
    log "Applies for real on first boot via ufw.service, same as frost-phase3.sh's server profile."
}

# ─────────────────────────────────────────────────────────────────────────
# 6. VPN TEMPLATES
# ─────────────────────────────────────────────────────────────────────────

has_placeholder() {
    grep -qE '<[A-Z_]+_HERE>' "$1" 2>/dev/null
}

setup_vpn() {
    step "VPN (WireGuard / OpenVPN)"
    if [[ "$SKIP_VPN" == true ]]; then
        warn "Skipping VPN setup (--skip-vpn)"; return 0
    fi
    ensure_chroot_network
    run chroot_exec "pacman -S --needed --noconfirm wireguard-tools openvpn"

    local wg_dir="${ROOT_PREFIX}/etc/wireguard"
    local ovpn_dir="${ROOT_PREFIX}/etc/openvpn/client"
    run mkdir -p "$wg_dir" "$ovpn_dir"

    local wg_template="${wg_dir}/frost-wg0.conf.template"
    run cp "${ASSETS_DIR}/wireguard/frost-wg0.conf.template" "$wg_template"
    run chmod 600 "$wg_template"
    CREATED_FILES+=("$wg_template")

    local ovpn_template="${ovpn_dir}/frost-client.conf.template"
    run cp "${ASSETS_DIR}/openvpn/frost-client.ovpn.template" "$ovpn_template"
    run chmod 600 "$ovpn_template"
    CREATED_FILES+=("$ovpn_template")

    success "VPN templates installed (not enabled — they're templates, not real configs)"
    log "Fill in $wg_template (or the OpenVPN one), rename to drop .template, then:"
    log "  wg:     sudo systemctl enable --now wg-quick@frost-wg0.service"
    log "  ovpn:   sudo systemctl enable --now openvpn-client@frost-client.service"

    if [[ "$ENABLE_VPN_AUTOCONNECT" == true ]]; then
        local wg_real="${wg_dir}/frost-wg0.conf"
        if [[ -f "$wg_real" ]] && ! has_placeholder "$wg_real"; then
            run chroot_exec "systemctl enable wg-quick@frost-wg0.service"
            success "wg-quick@frost-wg0.service enabled (WireGuard auto-connect on boot)"
        else
            warn "--enable-vpn-autoconnect was set, but no filled-in WireGuard config found at"
            warn "/etc/wireguard/frost-wg0.conf (or it still has <PLACEHOLDER> values) — not enabling."
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────
# 7. SSH HARDENING
# ─────────────────────────────────────────────────────────────────────────

harden_ssh() {
    step "SSH hardening"
    if [[ "$SKIP_SSH_HARDENING" == true ]]; then
        warn "Skipping SSH hardening (--skip-ssh-hardening)"; return 0
    fi
    ensure_chroot_network
    run chroot_exec "pacman -S --needed --noconfirm openssh fail2ban"

    local key_present=false
    if [[ -n "$TARGET_USER" ]]; then
        local auth_keys="${ROOT_PREFIX}/home/${TARGET_USER}/.ssh/authorized_keys"
        if [[ -s "$auth_keys" ]]; then
            key_present=true
        fi
    fi

    local dropin_dir="${ROOT_PREFIX}/etc/ssh/sshd_config.d"
    run mkdir -p "$dropin_dir"
    local dropin="${dropin_dir}/99-frost-hardening.conf"
    run cp "${ASSETS_DIR}/ssh/99-frost-hardening.conf.template" "$dropin"
    CREATED_FILES+=("$dropin")

    if [[ "$key_present" == true ]]; then
        success "authorized_keys found for ${TARGET_USER} — disabling password auth"
    else
        warn "No authorized_keys for ${TARGET_USER:-<unknown user>} — NOT disabling password"
        warn "auth (that would lock you out). Add a key first:"
        warn "  ssh-copy-id ${TARGET_USER:-<user>}@<this-host>"
        warn "then re-run: sudo ./${SCRIPT_NAME} --target ${FROST_TARGET}"
        if [[ "$DRY_RUN" != true ]]; then
            sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' "$dropin"
        fi
    fi

    local jail_dst="${ROOT_PREFIX}/etc/fail2ban/jail.local"
    run cp "${ASSETS_DIR}/fail2ban/jail.local" "$jail_dst"
    CREATED_FILES+=("$jail_dst")

    run chroot_exec "systemctl enable sshd.service"
    run chroot_exec "systemctl enable fail2ban.service"
    tool_success "sshd + fail2ban"
}

# ─────────────────────────────────────────────────────────────────────────
# 8. TOR (optional)
# ─────────────────────────────────────────────────────────────────────────

setup_tor() {
    step "Tor integration (optional)"
    if [[ "$ENABLE_TOR" != true ]]; then
        log "Tor not requested (pass --enable-tor to install it). Skipping."
        return 0
    fi
    ensure_chroot_network
    install_tool "tor" "tor" "" || true
    install_tool "torsocks" "torsocks" "" || true
    install_tool "torbrowser-launcher" "torbrowser-launcher" "torbrowser-launcher" || true
    run chroot_exec "systemctl enable tor.service"
    success "Tor daemon enabled. Use 'torsocks <cmd>' to route a single tool through it,"
    log "or torbrowser-launcher for the full browser. Never assume Tor alone anonymizes"
    log "active scanning traffic — most of these tools aren't built for it."
}

# ─────────────────────────────────────────────────────────────────────────
# 9. MAIN
# ─────────────────────────────────────────────────────────────────────────

write_marker() {
    [[ "$DRY_RUN" == true ]] && return 0
    local marker="${ROOT_PREFIX}/opt/frost/state/security.marker"
    mkdir -p "$(dirname "$marker")"
    cat > "$marker" <<EOF
name=security-and-hacking-tools
target_user=${TARGET_USER:-<none>}
aur_helper=${AUR_HELPER:-<none>}
firewall=$([[ "$SKIP_FIREWALL" != true ]] && echo true || echo false)
vpn_templates=$([[ "$SKIP_VPN" != true ]] && echo true || echo false)
vpn_autoconnect=${ENABLE_VPN_AUTOCONNECT}
ssh_hardened=$([[ "$SKIP_SSH_HARDENING" != true ]] && echo true || echo false)
tor=${ENABLE_TOR}
completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
script_version=${SCRIPT_VERSION}
EOF
    CREATED_FILES+=("$marker")
}

main() {
    banner
    log "FROST security pack starting — log: $LOG_FILE"
    [[ "$DRY_RUN" == true ]] && warn "DRY-RUN MODE: no changes will be made."

    if [[ ! -d "$ASSETS_DIR" ]]; then
        error "Config templates not found at ${ASSETS_DIR} — run this script from the FROST repo."
        exit 1
    fi

    check_root
    check_arch_linux
    detect_mode
    detect_target_user
    detect_aur_helper

    install_security_tools
    configure_firewall
    setup_vpn
    harden_ssh
    setup_tor
    write_marker

    trap - ERR

    step "FROST security pack complete"
    success "Target user     : ${TARGET_USER:-<none — AUR/SSH steps limited>}"
    success "AUR helper       : ${AUR_HELPER:-<none — AUR-only tools skipped>}"
    success "Firewall         : $([[ $SKIP_FIREWALL == true ]] && echo skipped || echo "ufw enabled")"
    success "VPN templates    : $([[ $SKIP_VPN == true ]] && echo skipped || echo "installed (fill in to use)")"
    success "SSH hardening    : $([[ $SKIP_SSH_HARDENING == true ]] && echo skipped || echo applied)"
    success "Tor              : $([[ $ENABLE_TOR == true ]] && echo installed || echo "not requested")"
    success "Log file         : ${LOG_FILE}"
    printf "\n%b🔐 Read SECURITY.README.md before you touch anything that isn't yours.%b\n\n" "${C_CYAN}${C_BOLD}" "${C_RESET}"
}

main "$@"
