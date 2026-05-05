#!/usr/bin/env bash
set -euo pipefail

DOMAIN="gui/$(id -u)"

uninstall_agent() {
    local label="$1"
    local plist_path="${HOME}/Library/LaunchAgents/${label}.plist"

    bootout_err=$(launchctl bootout "${DOMAIN}/${label}" 2>&1 >/dev/null) || rc=$?
    rc=${rc:-0}

    if [[ ${rc} -ne 0 ]]; then
        if echo "${bootout_err}" | grep -qiE "could not find|no such process|not loaded"; then
            : # already uninstalled — proceed.
        else
            echo "ERROR: launchctl bootout failed for ${label} (rc=${rc}): ${bootout_err}" >&2
            echo "       Plist left in place at ${plist_path}" >&2
            return "${rc}"
        fi
    fi

    rm -f "${plist_path}"
    echo "Uninstalled ${label}"
}

uninstall_agent "sh.saqoo.CCDiary.daily"
uninstall_agent "sh.saqoo.CCDiary.daily-generate"
