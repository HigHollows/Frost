#!/usr/bin/env bash
#
# frost-status.sh — FROST global health check / monitor
#
# Reports on: installed packs, systemd timer/service health, firewall,
# docker, disk space, config validity, pending updates, uptime. Writes
# a structured report to /var/log/frost/status.log every run.
#
# Usage:
#   frost-status.sh                  one-shot report, exit 0/1 (healthy/issues)
#   frost-status.sh --watch [secs]    loop forever (used by frost-daemon.service)
#   frost-status.sh --quiet             report file only, no stdout (for cron-like use)
#
# Author: FROST project
# License: MIT

set -uo pipefail  # no -e: every check should run even if one fails

if ! source /opt/frost/lib/frost-common.sh 2>/dev/null; then
    echo "frost-status: /opt/frost/lib/frost-common.sh not found — run frost-deploy.sh first" >&2
    exit 1
fi

REPORT="/var/log/frost/status.log"
QUIET=false
WATCH=false
WATCH_INTERVAL=300

while [[ $# -gt 0 ]]; do
    case "$1" in
        --watch) WATCH=true; [[ "${2:-}" =~ ^[0-9]+$ ]] && { WATCH_INTERVAL="$2"; shift; }; shift ;;
        --quiet) QUIET=true; shift ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--watch [seconds]] [--quiet]"
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

out() { $QUIET || printf '%s\n' "$*"; }

run_check() {
    load_config
    mkdir -p "$(dirname "$REPORT")"
    local issues=0
    local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    {
        echo "=== FROST status — ${now} ==="
        echo "FROST version: ${FROST_VERSION}"

        echo "--- Installed packs ---"
        for marker in phase1 phase2 phase3 branding security gaming; do
            if [[ -f "/opt/frost/state/${marker}.marker" ]]; then
                echo "  ${marker}: installed"
            else
                echo "  ${marker}: not installed"
            fi
        done

        echo "--- Deploy checkpoints ---"
        if [[ -f "$FROST_CHECKPOINT_FILE" ]]; then
            sed 's/^/  /' "$FROST_CHECKPOINT_FILE"
        else
            echo "  no deploy checkpoint recorded yet"
        fi

        echo "--- Config ---"
        if validate_config &>/dev/null; then
            echo "  ${FROST_CONF}: valid"
        else
            echo "  ${FROST_CONF}: MISSING or invalid (using built-in defaults)"
            issues=$((issues + 1))
        fi

        echo "--- systemd units ---"
        for unit in frost-daemon.service frost-security.timer frost-update.timer frost-performance.timer; do
            if systemctl list-unit-files "$unit" &>/dev/null && systemctl is-enabled --quiet "$unit" 2>/dev/null; then
                local active; active="$(systemctl is-active "$unit" 2>/dev/null || echo inactive)"
                echo "  ${unit}: enabled, ${active}"
                if [[ "$unit" == "frost-daemon.service" && "$active" != "active" ]]; then
                    issues=$((issues + 1))
                fi
            else
                echo "  ${unit}: not enabled"
            fi
        done

        echo "--- Firewall ---"
        if command -v ufw &>/dev/null; then
            local ufw_line; ufw_line="$(ufw status 2>/dev/null | head -n1)"
            echo "  ${ufw_line}"
            [[ "$ufw_line" != *active* ]] && issues=$((issues + 1))
        else
            echo "  ufw not installed"
        fi

        echo "--- Docker ---"
        if command -v docker &>/dev/null; then
            if systemctl is-active --quiet docker; then
                echo "  docker: running"
            else
                echo "  docker: installed but not running"
            fi
        else
            echo "  docker not installed"
        fi

        echo "--- Disk space ---"
        df -Ph / /opt/frost 2>/dev/null | sed 's/^/  /'
        local avail_kb; avail_kb="$(df -Pk / | awk 'NR==2{print $4}')"
        if [[ -n "$avail_kb" ]] && (( avail_kb < 5 * 1024 * 1024 )); then
            echo "  WARN: <5GB free on /"
            issues=$((issues + 1))
        fi

        echo "--- Pending updates ---"
        if command -v checkupdates &>/dev/null; then
            echo "  $(checkupdates 2>/dev/null | wc -l) official package update(s) pending"
        fi

        echo "--- Uptime ---"
        echo "  system: $(uptime -p 2>/dev/null || uptime)"
        if [[ -f "$FROST_CHECKPOINT_FILE" ]]; then
            echo "  FROST deployed since: $(stat -c '%y' "$FROST_CHECKPOINT_FILE" 2>/dev/null | cut -d. -f1)"
        fi

        echo "=== end status (${issues} issue(s)) ==="
    } > "${REPORT}.tmp"

    mv "${REPORT}.tmp" "$REPORT"
    out "$(cat "$REPORT")"

    if (( issues > 0 )); then
        warn "${issues} issue(s) detected — see ${REPORT}"
        notify_user "FROST status" "${issues} issue(s) detected — see ${REPORT}"
        return 1
    fi
    return 0
}

if [[ "$WATCH" == true ]]; then
    log "frost-status watching every ${WATCH_INTERVAL}s (Ctrl+C or systemctl stop frost-daemon to exit)"
    while true; do
        run_check || true
        sleep "$WATCH_INTERVAL"
    done
else
    run_check
    exit $?
fi
