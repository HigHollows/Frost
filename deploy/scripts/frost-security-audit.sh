#!/usr/bin/env bash
# frost-security-audit.sh — local security posture check, run daily by
# frost-security.timer. Installed to /opt/frost/bin/ by frost-deploy.sh.
#
# Scope, deliberately: THIS MACHINE ONLY. Firewall state, fail2ban bans,
# listening ports, pending updates, a couple of sshd_config sanity
# checks. It never scans or contacts anything else — an unattended timer
# has no way to confirm authorization for an external target, so it must
# never attempt that. If you want to actually run nmap/nikto/etc. against
# something, do it yourself, deliberately, with frost-security.sh's
# tools (a completely different script — this one only reads local
# system state).
set -uo pipefail  # not -e: we want every check to run even if one fails

source /opt/frost/lib/frost-common.sh 2>/dev/null || {
    echo "frost-security-audit: /opt/frost/lib/frost-common.sh not found — run frost-deploy.sh first" >&2
    exit 1
}
load_config

REPORT="/var/log/frost/security-audit.log"
mkdir -p "$(dirname "$REPORT")"
ISSUES=0

{
    echo "=== FROST security audit — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

    echo "--- Firewall ---"
    if command -v ufw &>/dev/null; then
        ufw_status="$(ufw status 2>/dev/null | head -n1)"
        echo "$ufw_status"
        if [[ "$ufw_status" != *"active"* ]]; then
            echo "ISSUE: ufw is installed but not active"
            ISSUES=$((ISSUES + 1))
        fi
    else
        echo "ufw not installed (run frost-security.sh)"
    fi

    echo "--- fail2ban ---"
    if command -v fail2ban-client &>/dev/null; then
        if systemctl is-active --quiet fail2ban; then
            fail2ban-client status 2>/dev/null | sed 's/^/  /'
        else
            echo "ISSUE: fail2ban installed but not running"
            ISSUES=$((ISSUES + 1))
        fi
    else
        echo "fail2ban not installed"
    fi

    echo "--- SSH hardening ---"
    if [[ -f /etc/ssh/sshd_config.d/99-frost-hardening.conf ]]; then
        if grep -q '^PermitRootLogin no' /etc/ssh/sshd_config.d/99-frost-hardening.conf; then
            echo "root login: disabled"
        fi
        if grep -q '^PasswordAuthentication no' /etc/ssh/sshd_config.d/99-frost-hardening.conf; then
            echo "password auth: disabled (key-only)"
        else
            echo "NOTE: password auth still enabled (no authorized_keys was found when frost-security.sh ran)"
        fi
    else
        echo "FROST SSH hardening not applied (run frost-security.sh)"
    fi

    echo "--- Listening ports ---"
    if command -v ss &>/dev/null; then
        ss -tulpn 2>/dev/null | tail -n +2 | sed 's/^/  /'
    fi

    echo "--- Pending package updates ---"
    if command -v checkupdates &>/dev/null; then
        pending="$(checkupdates 2>/dev/null | wc -l)"
        echo "${pending} official package update(s) pending"
    else
        echo "checkupdates not available (pacman-contrib not installed)"
    fi

    echo "=== end audit (${ISSUES} issue(s) flagged) ==="
} | tee -a "$REPORT"

if (( ISSUES > 0 )); then
    warn "${ISSUES} security posture issue(s) found — see ${REPORT}"
    notify_user "FROST security audit" "${ISSUES} issue(s) found — see ${REPORT}"
else
    success "Security audit clean — see ${REPORT}"
fi

exit 0
