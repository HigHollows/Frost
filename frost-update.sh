#!/usr/bin/env bash
#
# frost-update.sh — FROST update checker/applier
#
# Checks for official + AUR package updates, shows a colored changelog
# (old -> new version per package), and only ever APPLIES anything if
# explicitly told to (--apply, or FROST_AUTO_APPLY_UPDATES=true in
# /etc/frost/frost.conf) — the default is check-and-notify only.
#
# Usage:
#   frost-update.sh                just check, show changelog, exit
#   frost-update.sh --apply           check, confirm, then actually update
#   frost-update.sh --dry-run            explicit no-op preview (same as default check, spelled out)
#   frost-update.sh --yes                   auto-confirm the warning prompt (for scripted/unattended use)
#   frost-update.sh --from-timer               invoked by frost-update.timer — respects frost.conf, never prompts
#
# Author: FROST project
# License: MIT

set -uo pipefail

if ! source /opt/frost/lib/frost-common.sh 2>/dev/null; then
    echo "frost-update: /opt/frost/lib/frost-common.sh not found — run frost-deploy.sh first" >&2
    exit 1
fi
load_config

APPLY=false
AUTO_YES=false
FROM_TIMER=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)       APPLY=true; shift ;;
        --dry-run)     APPLY=false; shift ;;
        --yes)         AUTO_YES=true; shift ;;
        --from-timer)  FROM_TIMER=true; shift ;;
        -h|--help)
            cat <<EOF
Usage: $(basename "$0") [--apply] [--dry-run] [--yes] [--from-timer]
  (no flags)   check only, show changelog, exit
  --apply       actually run the update after showing the changelog
  --yes          skip the confirmation prompt (needed for unattended --apply)
  --from-timer      marks this as a systemd-timer run; respects
                       FROST_AUTO_APPLY_UPDATES from frost.conf instead of --apply
EOF
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ "$FROM_TIMER" == true ]]; then
    [[ "$FROST_AUTO_APPLY_UPDATES" == "true" ]] && APPLY=true || APPLY=false
    AUTO_YES=true  # a timer has no tty either way; warning_confirm already
                   # refuses unattended without --yes, this just makes the
                   # intent explicit for anyone reading the unit/log.
fi

step "Checking for updates"

if ! command -v checkupdates &>/dev/null; then
    warn "checkupdates not found (pacman-contrib not installed) — falling back to 'pacman -Sy' + 'pacman -Qu'."
    warn "This touches the live package database even in check-only mode, unlike checkupdates."
    sudo pacman -Sy --noconfirm &>/dev/null || true
    OFFICIAL_UPDATES="$(pacman -Qu 2>/dev/null || true)"
else
    OFFICIAL_UPDATES="$(checkupdates 2>/dev/null || true)"
fi

OFFICIAL_COUNT=0
[[ -n "$OFFICIAL_UPDATES" ]] && OFFICIAL_COUNT="$(printf '%s\n' "$OFFICIAL_UPDATES" | grep -c .)"

echo ""
if [[ -z "$OFFICIAL_UPDATES" ]]; then
    printf "%b  official packages up to date%b\n" "${C_GREEN}" "${C_RESET}"
else
    printf "%b  %d official package update(s):%b\n" "${C_BOLD}" "$OFFICIAL_COUNT" "${C_RESET}"
    # checkupdates/pacman -Qu format: "name old-ver -> new-ver"
    printf '%s\n' "$OFFICIAL_UPDATES" | while IFS= read -r line; do
        printf "  %b%s%b\n" "${C_YELLOW}" "$line" "${C_RESET}"
    done
fi

AUR_UPDATES=""
AUR_COUNT=0
if [[ "$FROST_UPDATE_CHECK_AUR" == "true" ]]; then
    AUR_HELPER=""
    command -v yay &>/dev/null && AUR_HELPER="yay"
    [[ -z "$AUR_HELPER" ]] && command -v paru &>/dev/null && AUR_HELPER="paru"

    if [[ -n "$AUR_HELPER" ]]; then
        target_user="${FROST_TARGET_USER:-$(logname 2>/dev/null || true)}"
        if [[ -n "$target_user" ]]; then
            AUR_UPDATES="$(sudo -u "$target_user" "$AUR_HELPER" -Qua 2>/dev/null || true)"
            [[ -n "$AUR_UPDATES" ]] && AUR_COUNT="$(printf '%s\n' "$AUR_UPDATES" | grep -c .)"
            echo ""
            if [[ -z "$AUR_UPDATES" ]]; then
                printf "%b  AUR packages up to date%b\n" "${C_GREEN}" "${C_RESET}"
            else
                printf "%b  %d AUR package update(s):%b\n" "${C_BOLD}" "$AUR_COUNT" "${C_RESET}"
                printf '%s\n' "$AUR_UPDATES" | while IFS= read -r line; do
                    printf "  %b%s%b\n" "${C_YELLOW}" "$line" "${C_RESET}"
                done
            fi
        else
            warn "AUR helper found but no target user known (set FROST_TARGET_USER in frost.conf) — skipping AUR check"
        fi
    fi
fi

TOTAL=$((OFFICIAL_COUNT + AUR_COUNT))
log_syslog "frost-update: ${TOTAL} update(s) available (${OFFICIAL_COUNT} official, ${AUR_COUNT} AUR)"

if (( TOTAL == 0 )); then
    success "Nothing to update."
    exit 0
fi

if [[ "$APPLY" != true ]]; then
    echo ""
    log "${TOTAL} update(s) available. Re-run with --apply to install them (or wait for the"
    log "weekly timer, if FROST_AUTO_APPLY_UPDATES=true in /etc/frost/frost.conf)."
    notify_user "FROST updates available" "${TOTAL} update(s) pending (${OFFICIAL_COUNT} official, ${AUR_COUNT} AUR)"
    exit 0
fi

if ! warning_confirm "About to apply ${TOTAL} update(s)" "$AUTO_YES"; then
    warn "Update cancelled."
    exit 1
fi

step "Applying updates"
if (( OFFICIAL_COUNT > 0 )); then
    sudo pacman -Syu --noconfirm
fi
if (( AUR_COUNT > 0 )) && [[ -n "${AUR_HELPER:-}" && -n "${target_user:-}" ]]; then
    sudo -u "$target_user" "$AUR_HELPER" -Sua --noconfirm
fi

success "Update complete (${TOTAL} package(s))."
notify_user "FROST updated" "${TOTAL} package(s) updated successfully."
log_syslog "frost-update: applied ${TOTAL} update(s) successfully"
