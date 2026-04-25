#!/usr/bin/env bash
set -euo pipefail
trap 'echo "ERROR: install failed at line $LINENO" >&2' ERR

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="sh.saqoo.CCDiary.daily"
PLIST_TEMPLATE="${ROOT_DIR}/launchd/${LABEL}.plist"
PLIST_DEST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs/CCDiary"
DOMAIN="gui/$(id -u)"
BIN_PATH="${ROOT_DIR}/build/Build/Products/Release/ccdiary-cli"

for cmd in xcodegen xcodebuild launchctl sed; do
    if ! command -v "${cmd}" >/dev/null; then
        echo "ERROR: required command not found: ${cmd}" >&2
        exit 1
    fi
done

mkdir -p "${HOME}/Library/LaunchAgents" "${LOG_DIR}"

echo "==> Regenerating Xcode project (xcodegen)"
xcodegen generate --spec "${ROOT_DIR}/project.yml"

echo "==> Building ccdiary-cli (Release)"
xcodebuild \
  -scheme ccdiary-cli \
  -configuration Release \
  -derivedDataPath "${ROOT_DIR}/build" \
  build

if [[ ! -x "${BIN_PATH}" ]]; then
    echo "ERROR: built binary not found at ${BIN_PATH}" >&2
    exit 1
fi

echo "==> Rendering LaunchAgent plist (substituting paths)"
# `|` as the sed delimiter so absolute paths don't need escaping. We render to
# the LaunchAgents directory directly so the in-repo template stays portable
# (no user-specific paths committed to the public repo).
sed \
    -e "s|@CCDIARY_BIN@|${BIN_PATH}|g" \
    -e "s|@LOG_DIR@|${LOG_DIR}|g" \
    "${PLIST_TEMPLATE}" > "${PLIST_DEST}"

# Sanity check: refuse to install if a placeholder slipped through.
if grep -q '@CCDIARY_BIN@\|@LOG_DIR@' "${PLIST_DEST}"; then
    echo "ERROR: placeholder substitution failed in ${PLIST_DEST}" >&2
    exit 1
fi

# Tear down any previous instance (ignore "not loaded" errors).
launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
launchctl bootstrap "${DOMAIN}" "${PLIST_DEST}"
launchctl enable "${DOMAIN}/${LABEL}"

# Confirm launchd actually accepted the agent (set -e fails if print returns non-zero).
launchctl print "${DOMAIN}/${LABEL}" >/dev/null

echo "Installed ${LABEL}"
echo "Plist: ${PLIST_DEST}"
echo "Logs:  ${LOG_DIR}/daily.out.log and ${LOG_DIR}/daily.err.log"
echo "Run a smoke test with: launchctl kickstart -k ${DOMAIN}/${LABEL} && tail -f ${LOG_DIR}/daily.err.log"
