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
