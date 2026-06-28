#!/usr/bin/env bash
set -euo pipefail
trap 'echo "ERROR: uninstall failed at line $LINENO" >&2' ERR

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=_launchd-paths.sh
source "${ROOT_DIR}/scripts/_launchd-paths.sh"

DOMAIN="gui/$(id -u)"

uninstall_agent() {
    local label="$1"
    local plist_path="${HOME}/Library/LaunchAgents/${label}.plist"
    # Declare per-invocation locals so a non-zero `rc` from the previous call
    # can't leak into this one — without `local`, the second invocation's
    # `bootout_err=… || rc=$?` would skip the assignment on success and
    # re-use the stale value, faking a failure for an agent that uninstalled
    # cleanly.
    local bootout_err rc=0

    bootout_err=$(launchctl bootout "${DOMAIN}/${label}" 2>&1 >/dev/null) || rc=$?

    if (( rc != 0 )); then
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

# Remove the installed binary copy (see install-daily-launch-agent.sh for the
# Documents-TCC rationale). The CCDiary parent directory under Application
# Support is intentionally left alone so any unrelated state — diary storage,
# logs, cached siblings — stays put. The bin/ subdirectory we created is
# rmdir'd best-effort: ENOTEMPTY is the expected outcome if something else
# dropped a file there; only that case is suppressed.
if [[ -e "${CCDIARY_BIN_INSTALL_PATH}" ]]; then
    rm -f "${CCDIARY_BIN_INSTALL_PATH}"
    echo "Removed installed binary ${CCDIARY_BIN_INSTALL_PATH}"
    # `LC_ALL=C` forces an English errno string so the case match below isn't
    # locale-dependent — a non-English shell would otherwise print "Note:" for
    # the expected ENOTEMPTY path.
    rmdir_err=$(LC_ALL=C rmdir "${CCDIARY_BIN_INSTALL_DIR}" 2>&1) || {
        case "${rmdir_err}" in
            *"Directory not empty"*) : ;;  # expected — leave whatever else is there.
            *) echo "Note: could not remove ${CCDIARY_BIN_INSTALL_DIR}: ${rmdir_err}" >&2 ;;
        esac
    }
fi
