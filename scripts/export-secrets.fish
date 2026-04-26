#!/usr/bin/env fish
# Export CCDiary secrets from Keychain into ~/.config/ccdiary/secrets so
# the daily LaunchAgent can read them without triggering Keychain prompts.
#
# macOS will prompt once per Keychain entry the first time `/usr/bin/security`
# touches it. Click "Always Allow" each time — `/usr/bin/security` is system-
# signed and stable, so the ACL stays valid across rebuilds (unlike the
# ad-hoc-signed ccdiary-cli binary).
#
# Usage:
#   ./scripts/export-secrets.fish [path]
#
# Defaults to $XDG_CONFIG_HOME/ccdiary/secrets or ~/.config/ccdiary/secrets.

set -l target $argv[1]
if test -z "$target"
    if set -q XDG_CONFIG_HOME; and test -n "$XDG_CONFIG_HOME"
        set target "$XDG_CONFIG_HOME/ccdiary/secrets"
    else
        set target "$HOME/.config/ccdiary/secrets"
    end
end

set -l target_dir (dirname -- "$target")
mkdir -p "$target_dir"

# service_name → env_var_name pairs the CLI looks up.
set -l mappings \
    "sh.saqoo.CCDiary.slack-bot-token=SLACK_BOT_TOKEN" \
    "sh.saqoo.CCDiary.gemini-api-key=GEMINI_API_KEY" \
    "sh.saqoo.CCDiary.claude-api-key=ANTHROPIC_API_KEY" \
    "sh.saqoo.CCDiary.openai-api-key=OPENAI_API_KEY" \
    "sh.saqoo.CCDiary.cloud-token=CCDIARY_CLOUD_TOKEN" \
    "sh.saqoo.CCDiary.cloud-endpoint=CCDIARY_CLOUD_ENDPOINT"

set -l tmp (mktemp)
# Restrict before writing — the file briefly holds tokens.
chmod 600 "$tmp"

set -l found 0
set -l missing
for pair in $mappings
    set -l service (string split -m 1 '=' -- $pair)[1]
    set -l envkey (string split -m 1 '=' -- $pair)[2]
    # The GUI app stores items without an account, so don't pin -a here.
    # `security` returns the first match by service, which is what we want.
    set -l value (security find-generic-password -s "$service" -w 2>/dev/null)
    if test -n "$value"
        printf '%s=%s\n' "$envkey" "$value" >> "$tmp"
        echo "  ✓ $envkey  ← $service"
        set found (math $found + 1)
    else
        set missing $missing "$envkey ($service)"
    end
end

if test $found -eq 0
    echo "No secrets found in Keychain. Nothing written." >&2
    rm -f "$tmp"
    exit 1
end

mv -f "$tmp" "$target"
chmod 600 "$target"
echo
echo "Wrote $found secret(s) to $target (mode 600)."

if test (count $missing) -gt 0
    echo
    echo "Skipped (not in Keychain):"
    for m in $missing
        echo "  · $m"
    end
end

echo
echo "Smoke test the LaunchAgent:"
echo "  launchctl kickstart -k gui/(id -u)/sh.saqoo.CCDiary.daily"
echo "  tail -f ~/Library/Logs/CCDiary/daily.err.log"
