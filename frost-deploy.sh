#!/usr/bin/env bash
#
# frost-deploy.sh — FROST master deployment orchestrator
#
# Chains every FROST script in dependency order: frost-build.sh (base) ->
# frost-phase2.sh (AUR/dotfiles) -> frost-phase3.sh (users/bootloader) ->
# frost-branding.sh -> frost-security.sh -> frost-gaming.sh (all three
# optional, skippable) -> installs the operations layer (frost-update.sh,
# frost-status.sh, frost-uninstall.sh, systemd timers, /etc/frost/frost.conf).
#
# What "rollback" means here: each sub-script already has its own
# trap-ERR rollback that undoes exactly what THAT run created on failure
# (see ARCHITECTURE.md). frost-deploy.sh does NOT attempt to also undo
# EARLIER, already-successful phases when a LATER phase fails — reversing
# a working pacstrap+bootloader+user setup because the gaming pack failed
# to install Steam would be far more dangerous than just stopping and
# telling you where it stopped. Checkpoints + --resume let you fix the
# problem and continue from where it broke instead.
#
# Usage:
#   sudo ./frost-deploy.sh --target /mnt --username you
#   sudo ./frost-deploy.sh --local --skip-branding --skip-gaming
#   sudo ./frost-deploy.sh --target /mnt --resume
#
# Author: FROST project
# License: MIT

set -uo pipefail  # deliberately not -e — see run_phase(): we want full
                   # control over exactly what a phase failure does,
                   # not an abrupt exit mid cleanup/reporting.

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_VERSION="0.1.0-deploy"
readonly FROST_SYSTEM_VERSION="2.0"
readonly LOG_FILE="/tmp/frost-deploy-$(date +%Y%m%d-%H%M%S).log"
readonly CHECKPOINT_FILE="/var/log/frost/deploy-checkpoint.state"

# ─────────────────────────────────────────────────────────────────────────
# 0. OUTPUT
# ─────────────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
    C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'
    C_BLUE='\033[1;34m'; C_CYAN='\033[1;36m'; C_BOLD='\033[1m'; C_RESET='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_BOLD=''; C_RESET=''
fi

log()     { printf "%b[frost]%b %s\n" "${C_CYAN}${C_BOLD}" "${C_RESET}" "$*" | tee -a "$LOG_FILE"; command -v logger &>/dev/null && logger -t frost-deploy -- "$*" || true; }
success() { printf "%b[  ok ]%b %s\n" "${C_GREEN}${C_BOLD}" "${C_RESET}" "$*" | tee -a "$LOG_FILE"; }
warn()    { printf "%b[ warn]%b %s\n" "${C_YELLOW}${C_BOLD}" "${C_RESET}" "$*" | tee -a "$LOG_FILE" >&2; }
critical() {
    printf "%b\xE2\x9D\x8C CRITICAL: %s. Rollback initiated...%b\n" "${C_RED}${C_BOLD}" "$1" "${C_RESET}" | tee -a "$LOG_FILE" >&2
    command -v logger &>/dev/null && logger -t frost-deploy -p user.err -- "CRITICAL: $1" || true
}
step()    { printf "\n%b==>%b %b%s%b\n" "${C_BLUE}${C_BOLD}" "${C_RESET}" "${C_BOLD}" "$*" "${C_RESET}" | tee -a "$LOG_FILE"; }

warning_confirm() {
    local msg="$1"
    printf "%b\xE2\x9A\xA0\xEF\xB8\x8F  WARNING: %s. Continue? (y/n) %b" "${C_YELLOW}${C_BOLD}" "$msg" "${C_RESET}"
    if [[ "$AUTO_YES" == true ]]; then echo "y  (--yes)"; return 0; fi
    if [[ ! -t 0 ]]; then echo "n  (no tty attached — pass --yes for unattended runs)"; return 1; fi
    local reply; read -r reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

banner() {
    printf "%b" "${C_CYAN}${C_BOLD}"
    cat <<'EOF'
 ███████╗██████╗  ██████╗ ███████╗████████╗
 ██╔════╝██╔══██╗██╔═══██╗██╔════╝╚══██╔══╝
 █████╗  ██████╔╝██║   ██║███████╗   ██║
 ██╔══╝  ██╔══██╗██║   ██║╚════██║   ██║
 ██║     ██║  ██║╚██████╔╝███████║   ██║
 ╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝
EOF
    printf "%b\n" "${C_RESET}"
    printf "%bFROST v%s - Ready for action \xF0\x9F\x9A\x80%b\n\n" "${C_BOLD}" "$FROST_SYSTEM_VERSION" "${C_RESET}"
}

progress_bar() {
    local current="$1" total="$2" label="$3"
    local pct=$(( current * 100 / total ))
    local filled=$(( pct / 5 ))
    local bar="" i
    for (( i = 0; i < 20; i++ )); do
        if (( i < filled )); then bar+="█"; else bar+="░"; fi
    done
    printf "\n%b[%s] %3d%% (%d/%d) \xE2\x9D\x84\xEF\xB8\x8F  %s%b\n" "${C_CYAN}${C_BOLD}" "$bar" "$pct" "$current" "$total" "$label" "${C_RESET}"
}

# ─────────────────────────────────────────────────────────────────────────
# 1. CHECKPOINTS
# ─────────────────────────────────────────────────────────────────────────

checkpoint_set() {
    local phase="$1" status="$2"
    mkdir -p "$(dirname "$CHECKPOINT_FILE")"
    if [[ -f "$CHECKPOINT_FILE" ]] && grep -q "^${phase}=" "$CHECKPOINT_FILE"; then
        sed -i "s/^${phase}=.*/${phase}=${status}/" "$CHECKPOINT_FILE"
    else
        echo "${phase}=${status}" >> "$CHECKPOINT_FILE"
    fi
}
checkpoint_get() {
    [[ -f "$CHECKPOINT_FILE" ]] || return 1
    grep "^${1}=" "$CHECKPOINT_FILE" | tail -n1 | cut -d= -f2
}

# ─────────────────────────────────────────────────────────────────────────
# 2. ARGUMENT PARSING
# ─────────────────────────────────────────────────────────────────────────

FROST_TARGET="/mnt"
FORCE_LOCAL=false
DRY_RUN=false
AUTO_YES=false
RESUME=false
SKIP_BRANDING=false
SKIP_SECURITY=false
SKIP_GAMING=false
DEPLOY_USERNAME=""
DEPLOY_PROFILE="none"

usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} — FROST master deployment orchestrator

Usage: sudo ./${SCRIPT_NAME} [options]

  --target <path>       pacstrap target (default: /mnt, bootstrap mode)
  --local                 Force local mode (provision the running system)
  --username <name>          Sudo user for frost-phase3.sh (password prompted)
  --profile <kind>              desktop|server|none, forwarded to frost-phase3.sh
  --skip-branding                  Skip frost-branding.sh
  --skip-security                     Skip frost-security.sh
  --skip-gaming                          Skip frost-gaming.sh
  --resume                                  Skip phases already checkpointed OK
  --yes                                        Auto-confirm warning prompts (unattended runs)
  --dry-run                                       Forward --dry-run to every phase, change nothing
  -h, --help                                        Show this help

Phase order: build -> phase2 -> phase3 -> branding -> security -> gaming
             -> operations layer (frost.conf, systemd timers, frost-update/
             status/uninstall). See DEPLOY.README.md for details.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)          FROST_TARGET="${2:?}"; shift 2 ;;
        --local)            FORCE_LOCAL=true; shift ;;
        --username)         DEPLOY_USERNAME="${2:?}"; shift 2 ;;
        --profile)          DEPLOY_PROFILE="${2:?}"; shift 2 ;;
        --skip-branding)    SKIP_BRANDING=true; shift ;;
        --skip-security)    SKIP_SECURITY=true; shift ;;
        --skip-gaming)      SKIP_GAMING=true; shift ;;
        --resume)           RESUME=true; shift ;;
        --yes)              AUTO_YES=true; shift ;;
        --dry-run)          DRY_RUN=true; shift ;;
        -h|--help)          usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

MODE_FLAG="--target"
MODE_VALUE="$FROST_TARGET"
[[ "$FORCE_LOCAL" == true ]] && { MODE_FLAG="--local"; MODE_VALUE=""; }

# ─────────────────────────────────────────────────────────────────────────
# 3. PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────

preflight() {
    step "Pre-flight checks"

    [[ "$EUID" -ne 0 ]] && { critical "Not running as root"; exit 1; }
    success "Running as root"

    command -v pacman &>/dev/null || { critical "pacman not found — not an Arch system"; exit 1; }
    success "Arch Linux confirmed"

    for script in frost-build.sh frost-phase2.sh frost-phase3.sh; do
        [[ -f "${SCRIPT_DIR}/${script}" ]] || { critical "${script} not found next to ${SCRIPT_NAME}"; exit 1; }
    done
    success "Core scripts present"

    local check_path="/"
    [[ "$FORCE_LOCAL" != true ]] && check_path="$FROST_TARGET"
    local avail_kb; avail_kb="$(df -Pk "$check_path" 2>/dev/null | awk 'NR==2{print $4}')"
    if [[ -n "$avail_kb" ]]; then
        local avail_gb=$(( avail_kb / 1024 / 1024 ))
        if (( avail_kb < 10 * 1024 * 1024 )); then
            warn "Only ~${avail_gb}GB free on ${check_path} — a full deploy (all packs) wants 15-20GB+."
            warning_confirm "Low disk space (~${avail_gb}GB free)" || { critical "Aborted: insufficient disk space"; exit 1; }
        else
            success "~${avail_gb}GB free on ${check_path}"
        fi
    else
        warn "Could not determine free space on ${check_path}"
    fi

    if command -v curl &>/dev/null && curl -s --max-time 5 -o /dev/null https://archlinux.org; then
        success "Network reachable"
    else
        warn "Could not reach archlinux.org — every phase needs network for pacman/AUR."
        warning_confirm "Network check failed" || { critical "Aborted: no network"; exit 1; }
    fi

    if [[ "$FORCE_LOCAL" != true ]]; then
        if ! mountpoint -q "$FROST_TARGET" 2>/dev/null; then
            critical "${FROST_TARGET} is not mounted — partition/format/mount it first (see frost-build.README.md)"
            exit 1
        fi
        if [[ -n "$(ls -A "$FROST_TARGET" 2>/dev/null)" ]] && [[ ! -f "${FROST_TARGET}/opt/frost/state/phase1.marker" ]]; then
            warn "${FROST_TARGET} is not empty and has no FROST Phase 1 marker — pacstrap over"
            warn "existing data can be destructive."
            warning_confirm "${FROST_TARGET} already has content on it" || { critical "Aborted by user"; exit 1; }
        fi
        success "Target ${FROST_TARGET} looks OK to proceed"
    fi
}

# ─────────────────────────────────────────────────────────────────────────
# 4. OPERATIONS LAYER INSTALL (lib, config, systemd units, ops scripts)
# ─────────────────────────────────────────────────────────────────────────

ROOT_PREFIX=""
[[ "$FORCE_LOCAL" != true ]] && ROOT_PREFIX="$FROST_TARGET"

install_operations_layer() {
    step "Installing operations layer (config, lib, systemd units)"
    local deploy_assets="${SCRIPT_DIR}/deploy"
    [[ -d "$deploy_assets" ]] || { critical "deploy/ assets not found next to ${SCRIPT_NAME}"; exit 1; }

    local lib_dir="${ROOT_PREFIX}/opt/frost/lib"
    local bin_dir="${ROOT_PREFIX}/opt/frost/bin"
    local etc_dir="${ROOT_PREFIX}/etc/frost"
    local unit_dir="${ROOT_PREFIX}/etc/systemd/system"
    mkdir -p "$lib_dir" "$bin_dir" "$etc_dir" "$unit_dir"

    cp "${deploy_assets}/lib/frost-common.sh" "$lib_dir/"
    cp "${deploy_assets}/scripts/frost-security-audit.sh" "$bin_dir/"
    chmod +x "${bin_dir}/frost-security-audit.sh"

    for f in frost-update.sh frost-status.sh frost-uninstall.sh; do
        cp "${SCRIPT_DIR}/${f}" "$bin_dir/"
        chmod +x "${bin_dir}/${f}"
        ln -sf "/opt/frost/bin/${f}" "${ROOT_PREFIX}/usr/local/bin/${f%.sh}" 2>/dev/null || true
    done

    if [[ ! -f "${etc_dir}/frost.conf" ]]; then
        cp "${deploy_assets}/config/frost.conf.template" "${etc_dir}/frost.conf"
        [[ -n "$DEPLOY_USERNAME" ]] && sed -i "s/^FROST_TARGET_USER=.*/FROST_TARGET_USER=\"${DEPLOY_USERNAME}\"/" "${etc_dir}/frost.conf"
        success "Installed /etc/frost/frost.conf"
    else
        log "/etc/frost/frost.conf already exists — leaving your edits in place"
    fi
    if ! bash -n "${etc_dir}/frost.conf" 2>/dev/null; then
        critical "The frost.conf we just installed doesn't parse as valid bash — this is a FROST bug, please report it"
        exit 1
    fi

    cp "${deploy_assets}/systemd/"*.service "${deploy_assets}/systemd/"*.timer "$unit_dir/"
    if [[ -n "$ROOT_PREFIX" ]]; then
        arch-chroot "$ROOT_PREFIX" systemctl daemon-reload 2>/dev/null || true
        for unit in frost-daemon.service frost-security.timer frost-update.timer frost-performance.timer; do
            arch-chroot "$ROOT_PREFIX" systemctl enable "$unit" 2>/dev/null || warn "Could not enable ${unit} (will need enabling after first real boot)"
        done
    else
        systemctl daemon-reload
        for unit in frost-daemon.service frost-security.timer frost-update.timer frost-performance.timer; do
            systemctl enable --now "$unit" 2>/dev/null || warn "Could not enable ${unit}"
        done
    fi
    success "Operations layer installed: frost.conf, lib, frost-update/status/uninstall, 4 systemd units"
}

# ─────────────────────────────────────────────────────────────────────────
# 5. PHASE RUNNER
# ─────────────────────────────────────────────────────────────────────────

TOTAL_PHASES=7
CURRENT_PHASE=0

run_phase() {
    local checkpoint_name="$1" label="$2" script="$3"; shift 3
    local extra_args=("$@")
    CURRENT_PHASE=$((CURRENT_PHASE + 1))
    progress_bar "$CURRENT_PHASE" "$TOTAL_PHASES" "$label"

    if [[ "$RESUME" == true && "$(checkpoint_get "$checkpoint_name")" == "ok" ]]; then
        log "Skipping ${label} — already checkpointed OK (--resume)"
        return 0
    fi

    checkpoint_set "$checkpoint_name" "running"
    local cmd=("${SCRIPT_DIR}/${script}")
    if [[ -n "$MODE_VALUE" ]]; then
        cmd+=("$MODE_FLAG" "$MODE_VALUE")
    else
        cmd+=("$MODE_FLAG")
    fi
    cmd+=("${extra_args[@]}")
    [[ "$DRY_RUN" == true ]] && cmd+=("--dry-run")

    log "Running: ${cmd[*]}"
    if "${cmd[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        checkpoint_set "$checkpoint_name" "ok"
        success "${label} complete"
        return 0
    else
        checkpoint_set "$checkpoint_name" "failed"
        critical "${label} failed"
        error_summary "$checkpoint_name" "$label"
        exit 1
    fi
}

error_summary() {
    local checkpoint_name="$1" label="$2"
    echo ""
    printf "%bDeployment stopped at: %s%b\n" "${C_RED}${C_BOLD}" "$label" "${C_RESET}"
    printf "Phases completed successfully before this (still in place, not rolled back):\n"
    [[ -f "$CHECKPOINT_FILE" ]] && grep '=ok$' "$CHECKPOINT_FILE" | sed 's/^/  /'
    printf "\n%s's own internal rollback already reverted whatever IT partially changed —\n" "$label"
    printf "see its log under /tmp/frost-*.log for details. Fix the underlying issue, then:\n"
    printf "  sudo ./%s %s%s --resume\n\n" "$SCRIPT_NAME" "$MODE_FLAG" "${MODE_VALUE:+ $MODE_VALUE}"
}

# ─────────────────────────────────────────────────────────────────────────
# 6. MAIN
# ─────────────────────────────────────────────────────────────────────────

main() {
    banner
    log "FROST deploy starting — log: $LOG_FILE"
    [[ "$DRY_RUN" == true ]] && warn "DRY-RUN MODE: every phase runs with --dry-run."
    [[ "$RESUME" == true ]] && log "Resume mode: phases already checkpointed OK will be skipped."

    preflight

    local phase3_args=()
    [[ -n "$DEPLOY_USERNAME" ]] && phase3_args+=(--username "$DEPLOY_USERNAME")
    [[ "$DEPLOY_PROFILE" != "none" ]] && phase3_args+=(--profile "$DEPLOY_PROFILE")

    run_phase "phase1"   "Phase 1: Foundations"            "frost-build.sh"
    run_phase "phase2"   "Phase 2: AUR & environment"       "frost-phase2.sh"
    run_phase "phase3"   "Phase 3: Users & bootloader"      "frost-phase3.sh" "${phase3_args[@]}"

    if [[ "$SKIP_BRANDING" == true ]]; then
        CURRENT_PHASE=$((CURRENT_PHASE + 1)); log "Skipping Boot & Aesthetic pack (--skip-branding)"
    else
        run_phase "branding" "Boot & Aesthetic pack"          "frost-branding.sh"
    fi

    if [[ "$SKIP_SECURITY" == true ]]; then
        CURRENT_PHASE=$((CURRENT_PHASE + 1)); log "Skipping Security & Hacking Tools pack (--skip-security)"
    else
        run_phase "security" "Security & Hacking Tools pack"     "frost-security.sh"
    fi

    if [[ "$SKIP_GAMING" == true ]]; then
        CURRENT_PHASE=$((CURRENT_PHASE + 1)); log "Skipping Gaming & Dev Stack pack (--skip-gaming)"
    else
        run_phase "gaming"   "Gaming & Dev Stack pack"           "frost-gaming.sh"
    fi

    CURRENT_PHASE=$((CURRENT_PHASE + 1))
    progress_bar "$CURRENT_PHASE" "$TOTAL_PHASES" "Operations layer"
    if [[ "$DRY_RUN" != true ]]; then
        install_operations_layer
    else
        log "(dry-run) would install operations layer here"
    fi
    checkpoint_set "operations" "ok"

    step "Deployment summary"
    [[ -f "$CHECKPOINT_FILE" ]] && sed 's/^/  /' "$CHECKPOINT_FILE"

    final_success
}

final_success() {
    printf "\n%b\xF0\x9F\x8E\x89 FROST SYSTEM DEPLOYED SUCCESSFULLY!%b\n" "${C_GREEN}${C_BOLD}" "${C_RESET}"
    printf "%bFROST v%s - Ready for action \xF0\x9F\x9A\x80%b\n\n" "${C_BOLD}" "$FROST_SYSTEM_VERSION" "${C_RESET}"
    log "Check overall health any time: frost-status  (or: systemctl status 'frost-*')"
    log "Log file: ${LOG_FILE}"
}

main "$@"
