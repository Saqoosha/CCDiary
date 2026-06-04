#!/usr/bin/env bash
set -euo pipefail
trap 'echo "ERROR: install failed at line $LINENO" >&2' ERR

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="sh.saqoo.CCDiary.daily"
GENERATE_LABEL="sh.saqoo.CCDiary.daily-generate"
PLIST_TEMPLATE="${ROOT_DIR}/launchd/${LABEL}.plist"
GENERATE_PLIST_TEMPLATE="${ROOT_DIR}/launchd/${GENERATE_LABEL}.plist"
PLIST_DEST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
GENERATE_PLIST_DEST="${HOME}/Library/LaunchAgents/${GENERATE_LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs/CCDiary"
DOMAIN="gui/$(id -u)"
BIN_PATH="${ROOT_DIR}/build/Build/Products/Release/ccdiary-cli"

MODE="push-only"

usage() {
    cat <<EOF
Usage: $0 [--mode push-only|primary]

  --mode push-only   Install only the push-stats agent (default, for every Mac).
  --mode primary     Install both push-stats AND daily-generate agents (primary Mac only).
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            shift
            if [[ $# -eq 0 ]]; then
                echo "ERROR: --mode requires an argument (push-only or primary)" >&2
                exit 1
            fi
            MODE="$1"
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage
            ;;
    esac
    shift
done

if [[ "${MODE}" != "push-only" && "${MODE}" != "primary" ]]; then
    echo "ERROR: --mode must be 'push-only' or 'primary'" >&2
    exit 1
fi

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

# Code-sign the CLI with a stable identity.
#
# The default Xcode build leaves ccdiary-cli ad-hoc signed. An ad-hoc signature's
# code-signing requirement is CDHash-based, so it changes on EVERY rebuild — which
# makes macOS treat the binary as a brand-new app and invalidates any TCC
# (Full Disk Access) and Keychain grants it was previously given. That's what would
# make the unattended 4am run pop a permission dialog (and stall) after a rebuild.
#
# Signing with a stable Developer ID identity gives the binary a constant
# requirement, so TCC/Keychain grants survive rebuilds and Claude Code auto-updates.
# Override the identity for forks/other machines via CCDIARY_SIGN_IDENTITY.
SIGN_IDENTITY="${CCDIARY_SIGN_IDENTITY:-Developer ID Application: Whatever Co. (G5G54TCH8W)}"
if security find-identity -v -p codesigning | grep -qF "${SIGN_IDENTITY}"; then
    echo "==> Code-signing ccdiary-cli (${SIGN_IDENTITY})"
    if ! codesign --force --sign "${SIGN_IDENTITY}" "${BIN_PATH}"; then
        echo "ERROR: codesign failed for ${BIN_PATH} with identity '${SIGN_IDENTITY}'." >&2
        echo "       Refusing to install an unsigned agent (TCC/Keychain grants would not persist)." >&2
        exit 1
    fi
    codesign -dvv "${BIN_PATH}" 2>&1 | grep -E 'Authority=|TeamIdentifier=' | sed 's/^/    /'
else
    # Without a stable signature the binary stays ad-hoc, whose requirement changes
    # every rebuild and resets TCC/Keychain grants — the unattended 04:00 run would
    # then stall on a permission prompt. Refuse to install a setup that defeats the
    # whole point of this agent rather than warning and continuing.
    echo "ERROR: code-signing identity not found: ${SIGN_IDENTITY}" >&2
    echo "       A stable signature is required so TCC/Keychain grants survive rebuilds." >&2
    echo "       List identities with 'security find-identity -v -p codesigning' and set" >&2
    echo "       CCDIARY_SIGN_IDENTITY to a Developer ID or a persistent self-signed cert." >&2
    exit 1
fi

render_and_install() {
    local template="$1"
    local dest="$2"
    local label="$3"

    local host_name
	host_name=$(scutil --get LocalHostName 2>/dev/null || echo "unknown")
	echo "==> Rendering ${label} plist (host=${host_name})"
    sed \
        -e "s|@CCDIARY_BIN@|${BIN_PATH}|g" \
        -e "s|@LOG_DIR@|${LOG_DIR}|g" \
        -e "s|@HOST_NAME@|${host_name}|g" \
        "${template}" > "${dest}"

    if grep -q '@CCDIARY_BIN@\|@LOG_DIR@\|@HOST_NAME@' "${dest}"; then
        echo "ERROR: placeholder substitution failed in ${dest}" >&2
        exit 1
    fi

    # Tear down any previous instance (ignore "not loaded" errors).
    launchctl bootout "${DOMAIN}/${label}" 2>/dev/null || true
    launchctl bootstrap "${DOMAIN}" "${dest}"
    launchctl enable "${DOMAIN}/${label}"

    launchctl print "${DOMAIN}/${label}" >/dev/null

    echo "Installed ${label}"
    echo "Plist: ${dest}"
}

# Always install the push-stats agent (runs on every Mac).
render_and_install "${PLIST_TEMPLATE}" "${PLIST_DEST}" "${LABEL}"

if [[ "${MODE}" == "primary" ]]; then
    render_and_install "${GENERATE_PLIST_TEMPLATE}" "${GENERATE_PLIST_DEST}" "${GENERATE_LABEL}"
fi

echo ""
echo "Logs:  ${LOG_DIR}/daily.out.log and ${LOG_DIR}/daily.err.log"
echo "Run a smoke test with:"
echo "  launchctl kickstart -k ${DOMAIN}/${LABEL} && tail -f ${LOG_DIR}/daily.err.log"
if [[ "${MODE}" == "primary" ]]; then
    echo "  launchctl kickstart -k ${DOMAIN}/${GENERATE_LABEL} && tail -f ${LOG_DIR}/daily.err.log"
fi
