# shellcheck shell=bash
# Single source of truth for where the launchd-invoked ccdiary-cli binary lives.
# Sourced from install-daily-launch-agent.sh and uninstall-daily-launch-agent.sh
# so the two scripts can never drift on the install location. See the rationale
# block in install-daily-launch-agent.sh for *why* the binary lives here rather
# than under the build tree.

# shellcheck disable=SC2034  # Consumed by the sourcing script, not used locally.
CCDIARY_BIN_INSTALL_DIR="${HOME}/Library/Application Support/CCDiary/bin"
# shellcheck disable=SC2034  # Consumed by the sourcing script, not used locally.
CCDIARY_BIN_INSTALL_PATH="${CCDIARY_BIN_INSTALL_DIR}/ccdiary-cli"
