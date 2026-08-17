#!/usr/bin/env bash
# Renders /etc/frost/motd.template -> /etc/motd, substituting the
# variables from /etc/frost/branding.conf and the {{COLOR}} tags for
# real ANSI escapes. Safe to re-run any time you edit branding.conf.
#
# Usage: sudo frost-motd-render.sh
set -euo pipefail

CONF="/etc/frost/branding.conf"
TEMPLATE="/etc/frost/motd.template"
OUT="/etc/motd"

if [[ ! -f "$CONF" ]]; then
    echo "frost-motd-render: $CONF not found (see branding.conf.example)" >&2
    exit 1
fi
if [[ ! -f "$TEMPLATE" ]]; then
    echo "frost-motd-render: $TEMPLATE not found" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$CONF"

# Real ANSI escapes (ANSI-C quoting gives us the literal ESC byte).
RED=$'\033[1;31m'
CYAN=$'\033[1;36m'
ICE=$'\033[0;96m'
DIM=$'\033[2m'
RESET=$'\033[0m'

render() {
    sed \
        -e "s/{{RED}}/${RED}/g" \
        -e "s/{{CYAN}}/${CYAN}/g" \
        -e "s/{{ICE}}/${ICE}/g" \
        -e "s/{{DIM}}/${DIM}/g" \
        -e "s/{{RESET}}/${RESET}/g" \
        -e "s/{{FROST_VERSION}}/${FROST_VERSION:-0.1.0}/g" \
        -e "s#{{FROST_TAGLINE}}#${FROST_TAGLINE:-minimalist Arch for full-stack devs}#g" \
        -e "s/{{FROST_FAKE_ERROR}}/${FROST_FAKE_ERROR:-}/g" \
        "$TEMPLATE"
}

if [[ -z "${FROST_FAKE_ERROR:-}" ]]; then
    # Drop the whole fake-error line when it's disabled, rather than
    # leaving a dangling "$ ERROR: " with nothing after it.
    render | grep -v "ERROR:" > "$OUT"
else
    render > "$OUT"
fi

echo "frost-motd-render: wrote $OUT"
