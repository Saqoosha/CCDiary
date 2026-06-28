#!/usr/bin/env bash
set -euo pipefail
trap 'echo "ERROR: install failed at line $LINENO" >&2' ERR

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=_launchd-paths.sh
source "${ROOT_DIR}/scripts/_launchd-paths.sh"
LABEL="sh.saqoo.CCDiary.daily"
GENERATE_LABEL="sh.saqoo.CCDiary.daily-generate"
PLIST_TEMPLATE="${ROOT_DIR}/launchd/${LABEL}.plist"
GENERATE_PLIST_TEMPLATE="${ROOT_DIR}/launchd/${GENERATE_LABEL}.plist"
PLIST_DEST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
GENERATE_PLIST_DEST="${HOME}/Library/LaunchAgents/${GENERATE_LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs/CCDiary"
DOMAIN="gui/$(id -u)"
BIN_BUILD_PATH="${ROOT_DIR}/build/Build/Products/Release/ccdiary-cli"
# Install the launchd binary OUTSIDE ~/Documents. Empirically observed on
# Saqoosha's Mac Studio: when a Documents-TCC consent dialog is pending in the
# user session (typically triggered by a Claude Code auto-update touching
# ~/Documents), the 04:00/04:05 launchd fires don't run on time if the
# LaunchAgent's binary lives under ~/Documents — the post arrives only after
# the dialog is dismissed, often hours later. The exact gating layer (TCC,
# exec policy, launchd's launch path, or the pending dialog blocking the user
# session) isn't proven, but moving the installed binary to
# ~/Library/Application Support/CCDiary/bin reliably eliminates the symptom
# because that path doesn't sit behind the Documents consent prompt. The repo,
# build output, and signing happen in-place; only the installed copy moves out.
#
# Do NOT point the LaunchAgent at the build path under ~/Documents — that
# re-arms the failure mode.
BIN_INSTALL_DIR="${CCDIARY_BIN_INSTALL_DIR}"
BIN_PATH="${CCDIARY_BIN_INSTALL_PATH}"

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

if [[ ! -x "${BIN_BUILD_PATH}" ]]; then
    echo "ERROR: built binary not found at ${BIN_BUILD_PATH}" >&2
    exit 1
fi

# Stage the new binary next to its final path, sign it there, then atomically
# `mv` into place. Never overwrite ${BIN_PATH} in-place: if codesign (or any
# other step between cp and the final rename) fails, the live LaunchAgent
# would otherwise be left pointing at an unsigned/ad-hoc copy that defeats the
# whole TCC/Keychain stability the install script exists to protect. mktemp
# under BIN_INSTALL_DIR keeps the staging file on the same filesystem so the
# final mv is atomic; the trap cleans up the partial copy on any earlier
# failure path.
echo "==> Installing ccdiary-cli to ${BIN_PATH}"
if ! mkdir -p "${BIN_INSTALL_DIR}"; then
    echo "ERROR: failed to create ${BIN_INSTALL_DIR}" >&2
    exit 1
fi
if ! BIN_STAGING_PATH="$(mktemp "${BIN_INSTALL_DIR}/ccdiary-cli.XXXXXX")"; then
    echo "ERROR: failed to create staging file under ${BIN_INSTALL_DIR}" >&2
    exit 1
fi
# shellcheck disable=SC2154  # rc is assigned at the start of this same trap body.
trap 'rc=$?; rm -f "${BIN_STAGING_PATH}"; echo "ERROR: install failed at line $LINENO" >&2; exit $rc' ERR
if ! cp -p "${BIN_BUILD_PATH}" "${BIN_STAGING_PATH}"; then
    echo "ERROR: failed to copy ${BIN_BUILD_PATH} → ${BIN_STAGING_PATH}" >&2
    exit 1
fi
if [[ ! -x "${BIN_STAGING_PATH}" ]]; then
    echo "ERROR: staged binary not executable at ${BIN_STAGING_PATH}" >&2
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
    if ! codesign --force --sign "${SIGN_IDENTITY}" "${BIN_STAGING_PATH}"; then
        echo "ERROR: codesign failed for ${BIN_STAGING_PATH} with identity '${SIGN_IDENTITY}'." >&2
        echo "       Refusing to install an unsigned agent (TCC/Keychain grants would not persist)." >&2
        exit 1
    fi
    codesign -dvv "${BIN_STAGING_PATH}" 2>&1 | grep -E 'Authority=|TeamIdentifier=' | sed 's/^/    /'
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

# Atomically swap the signed staging copy into place. Same-filesystem mv is
# atomic, so the LaunchAgent at BIN_PATH either sees the old signed binary or
# the new signed binary — never a partial or unsigned write. After this point
# the staging trap is no longer needed.
if ! mv -f "${BIN_STAGING_PATH}" "${BIN_PATH}"; then
    echo "ERROR: failed to swap staged binary into ${BIN_PATH}" >&2
    exit 1
fi
trap 'echo "ERROR: install failed at line $LINENO" >&2' ERR

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
