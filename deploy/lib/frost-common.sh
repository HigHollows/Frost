#!/usr/bin/env bash
# frost-common.sh — shared helpers for FROST's operations layer
# (frost-deploy.sh, frost-update.sh, frost-status.sh, frost-uninstall.sh
# and the systemd service scripts).
#
# Installed to /opt/frost/lib/frost-common.sh by frost-deploy.sh. Source
# it, don't execute it: `source /opt/frost/lib/frost-common.sh`.
#
# NOTE on scope: the six build-time scripts (frost-build.sh, frost-phase2/
# 3.sh, frost-branding.sh, frost-security.sh, frost-gaming.sh) deliberately
# stay standalone/self-contained per FROST's own design principle #1 ("read
# before you run", no hidden dependencies) — they might run from a bare
# live ISO before this file even exists. This lib is only for the
# "already-deployed, ongoing operations" layer, which by definition only
# ever runs after frost-deploy.sh has installed it.

# ── Output ──────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
    C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'
    C_BLUE='\033[1;34m'; C_CYAN='\033[1;36m'; C_BOLD='\033[1m'; C_RESET='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_BOLD=''; C_RESET=''
fi

: "${FROST_LOG_FILE:=/var/log/frost/frost.log}"

_frost_log_line() {
    local dir; dir="$(dirname "$FROST_LOG_FILE")"
    # /var/log/frost is written by both root (frost-daemon.service,
    # frost-deploy.sh) and interactive non-root users (running frost-status
    # by hand). 1777 (world-writable, sticky bit — same idea as /tmp) is the
    # simplest thing that lets both write without one clobbering the other's
    # permission on files it doesn't own. frost-deploy.sh sets this at
    # creation time; the chmod here is just a best-effort self-heal if this
    # ever runs before that (silently no-ops for a non-owning non-root user,
    # which is fine — nothing worse than before).
    mkdir -p "$dir" 2>/dev/null
    chmod 1777 "$dir" 2>/dev/null || true
    printf '%s\n' "$1" >> "$FROST_LOG_FILE" 2>/dev/null || true
}

log()     { printf "%b[frost]%b %s\n" "${C_CYAN}${C_BOLD}" "${C_RESET}" "$*"; _frost_log_line "[frost] $*"; }
success() { printf "%b[  ok ]%b %s\n" "${C_GREEN}${C_BOLD}" "${C_RESET}" "$*"; _frost_log_line "[ok] $*"; }
warn()    { printf "%b[ warn]%b %s\n" "${C_YELLOW}${C_BOLD}" "${C_RESET}" "$*" >&2; _frost_log_line "[warn] $*"; }
error()   { printf "%b[FATAL]%b %s\n" "${C_RED}${C_BOLD}" "${C_RESET}" "$*" >&2; _frost_log_line "[error] $*"; }
step()    { printf "\n%b==>%b %b%s%b\n" "${C_BLUE}${C_BOLD}" "${C_RESET}" "${C_BOLD}" "$*" "${C_RESET}"; _frost_log_line "==> $*"; }

# Also mirror to syslog/journal — frost-deploy.sh's "file + syslog"
# logging requirement. `logger` is part of util-linux, always present.
log_syslog() {
    command -v logger &>/dev/null && logger -t "frost" -- "$1" 2>/dev/null || true
}

# ── "Final boss" error-handling phrasing (exact requested wording) ──────

critical() {
    printf "%b\xE2\x9D\x8C CRITICAL: %s. Rollback initiated...%b\n" "${C_RED}${C_BOLD}" "$1" "${C_RESET}" >&2
    _frost_log_line "[CRITICAL] $1"
    log_syslog "CRITICAL: $1"
}

# warning_confirm <message> [--yes-flag-value]
# Interactive: prompts "y/n" and returns 0 only on yes. Non-interactive
# (no tty, or --yes was passed by the caller) never silently guesses —
# it treats "no tty and no --yes" as a NO, so an unattended run fails
# safe instead of plowing through a warning nobody saw.
warning_confirm() {
    local msg="$1" auto_yes="${2:-false}"
    printf "%b\xE2\x9A\xA0\xEF\xB8\x8F  WARNING: %s. Continue? (y/n) %b" "${C_YELLOW}${C_BOLD}" "$msg" "${C_RESET}"
    _frost_log_line "[WARNING] $msg"

    if [[ "$auto_yes" == true ]]; then
        echo "y  (--yes)"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        echo "n  (no tty attached, refusing to guess — pass --yes to auto-confirm unattended runs)"
        return 1
    fi
    local reply
    read -r reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

final_success() {
    printf "\n%b\xF0\x9F\x8E\x89 FROST SYSTEM DEPLOYED SUCCESSFULLY!%b\n" "${C_GREEN}${C_BOLD}" "${C_RESET}"
    _frost_log_line "[SUCCESS] FROST SYSTEM DEPLOYED SUCCESSFULLY"
    log_syslog "FROST system deployed successfully"
}

# ── Config (/etc/frost/frost.conf) ───────────────────────────────────────

FROST_CONF="${FROST_CONF:-/etc/frost/frost.conf}"

# Validates frost.conf is syntactically sound bash *without* sourcing it
# into the current shell first — catches a stray quote/paren before it
# can do anything weird. Safe to call standalone (e.g. from frost-status.sh
# just to report validity).
validate_config() {
    local conf="${1:-$FROST_CONF}"
    [[ -f "$conf" ]] || { warn "config: $conf does not exist"; return 1; }
    if ! bash -n "$conf" 2>/dev/null; then
        error "config: $conf has a syntax error"
        bash -n "$conf" 2>&1 | sed 's/^/  /' >&2
        return 1
    fi
    return 0
}

# Populates FROST_* variables: config file values win, sane defaults fill
# in anything missing (including a totally absent file).
load_config() {
    FROST_VERSION="2.0"
    FROST_COMPONENTS="core"
    FROST_TARGET_USER=""
    FROST_AUTO_APPLY_UPDATES="false"
    FROST_UPDATE_CHECK_AUR="true"
    FROST_PERFORMANCE_MODE="balanced"

    if [[ -f "$FROST_CONF" ]]; then
        if validate_config "$FROST_CONF"; then
            # shellcheck disable=SC1090
            source "$FROST_CONF"
        else
            warn "Ignoring invalid $FROST_CONF, using built-in defaults"
        fi
    fi
}

# ── Desktop notifications from a root/system context ─────────────────────

# systemd timers run as root with no desktop session of their own — this
# finds a logged-in user and posts to *their* session bus. Best-effort:
# never fails the caller, just silently no-ops if there's no notify-send
# or nobody logged in graphically.
notify_user() {
    local title="$1" body="$2"
    command -v notify-send &>/dev/null || return 0

    local user uid
    user="$(loginctl list-users --no-legend 2>/dev/null | awk '{print $2}' | head -n1)"
    [[ -z "$user" ]] && return 0
    uid="$(id -u "$user" 2>/dev/null)" || return 0

    sudo -u "$user" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
        notify-send "$title" "$body" 2>/dev/null || true
}

# ── Checkpoints (used by frost-deploy.sh, readable by frost-status.sh) ───

FROST_CHECKPOINT_FILE="${FROST_CHECKPOINT_FILE:-/var/log/frost/deploy-checkpoint.state}"

checkpoint_set() {
    local phase="$1" status="$2"
    mkdir -p "$(dirname "$FROST_CHECKPOINT_FILE")"
    # One line per phase; last write for a given phase wins.
    if [[ -f "$FROST_CHECKPOINT_FILE" ]] && grep -q "^${phase}=" "$FROST_CHECKPOINT_FILE"; then
        sed -i "s/^${phase}=.*/${phase}=${status}/" "$FROST_CHECKPOINT_FILE"
    else
        echo "${phase}=${status}" >> "$FROST_CHECKPOINT_FILE"
    fi
}

checkpoint_get() {
    local phase="$1"
    [[ -f "$FROST_CHECKPOINT_FILE" ]] || return 1
    grep "^${phase}=" "$FROST_CHECKPOINT_FILE" | tail -n1 | cut -d= -f2
}
