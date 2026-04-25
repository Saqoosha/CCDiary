#!/usr/bin/env bash
set -euo pipefail

LABEL="sh.saqoo.CCDiary.daily"
PLIST_DEST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
DOMAIN="gui/$(id -u)"

# Capture bootout output so we can ignore "not loaded" but surface real failures
# (permission denied, SIP-blocked, stuck job). Otherwise we'd silently rm the
# plist while the agent is still running.
bootout_err=$(launchctl bootout "${DOMAIN}/${LABEL}" 2>&1 >/dev/null) || rc=$?
rc=${rc:-0}

if [[ ${rc} -ne 0 ]]; then
    if echo "${bootout_err}" | grep -qiE "could not find|no such process|not loaded"; then
        : # already uninstalled — proceed.
    else
        echo "ERROR: launchctl bootout failed (rc=${rc}): ${bootout_err}" >&2
        echo "       Plist left in place at ${PLIST_DEST}" >&2
        exit "${rc}"
    fi
fi

rm -f "${PLIST_DEST}"
echo "Uninstalled ${LABEL}"
