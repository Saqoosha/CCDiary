# Development Guide for CCDiary

## Project Structure

- **Swift macOS app** using SwiftUI
- Project managed by `xcodegen` via `project.yml`
- Dependencies managed by Swift Package Manager

## Development Workflow

### 1. After modifying code

```bash
# If new files were added, regenerate Xcode project
xcodegen generate

# Build
xcodebuild -scheme CCDiary -configuration Debug -derivedDataPath build build

# Run
open build/Build/Products/Debug/CCDiary.app
```

### 2. Kill running app before rebuild

```bash
pkill -f CCDiary
```

### 3. Quick iteration

```bash
pkill -f CCDiary; xcodebuild -scheme CCDiary -configuration Debug -derivedDataPath build build 2>&1 | tail -5 && open build/Build/Products/Debug/CCDiary.app
```

## Key Points

- **Always use `xcodebuild`** for building, not `swift build` (app requires proper signing and bundling)
- **Run `xcodegen generate`** after adding new source files
- Build output goes to `build/Build/Products/Debug/`
- Statistics cache stored in `~/Library/Caches/CCDiary/statistics/`

## Debugging

### Viewing logs

Use `logger.notice` (not `logger.info`) for logs that need to be persisted and visible:

```swift
import os.log
private let logger = Logger(subsystem: "CCDiary", category: "MyService")
logger.notice("Message here")
```

View logs with:

```bash
/usr/bin/log show --predicate 'subsystem == "CCDiary"' --last 30s
```

### Testing with clean state

**Important:** Always kill the app by PID, not by pattern matching (to avoid killing other processes):

```bash
# Find the PID
ps aux | grep CCDiary.app | grep -v grep

# Kill by PID
kill <PID>

# Clear all caches
rm -rf ~/Library/Caches/CCDiary/

# Rebuild and run
xcodebuild -scheme CCDiary -configuration Debug -derivedDataPath build build 2>&1 | tail -3
open build/Build/Products/Debug/CCDiary.app
```

### Testing specific dates on launch

To auto-load a specific date on launch for testing, temporarily modify `ContentView.swift`:

```swift
// Change this:
var selectedDate: Date = Date()

// To this (example for 2026-01-22):
var selectedDate: Date = DateFormatting.iso.date(from: "2026-01-22") ?? Date()
```

**Remember to revert after testing!**

## Architecture

- `Sources/CCDiary/Models/` - Data models
- `Sources/CCDiary/Views/` - SwiftUI views
- `Sources/CCDiary/Services/` - Business logic and data access
  - `HistoryService` - Reads Claude Code history
  - `ConversationService` - Reads conversation JSONL files (with binary search optimization)
  - `CodexService` - Reads Codex CLI/App session history (jsonl + legacy json)
  - `AggregatorService` - Aggregates daily activity data
  - `StatisticsCache` - Caches statistics for past dates
  - `DiaryStorage` - Saves/loads diary entries
  - `AIAPIService` - Common protocol/error model for AI providers
  - `ClaudeAPIService` - Generates diaries via Claude API
  - `GeminiAPIService` - Generates diaries via Gemini API
  - `OpenAIAPIService` - Generates diaries via OpenAI API
  - `SlackService` - Posts generated diaries to Slack
  - `CloudIngestService` - Pushes diaries (with stats) to the Cloudflare Worker at [`web/`](web/)

## Performance Optimizations

### Diary Generation (aggregateForDate)

Multiple optimizations reduce diary generation time from ~14s to ~2s:

1. **Date Index Filtering**
   - Only processes files that contain the target date
   - Reduces file count by ~87% (e.g., 135 → 17 files)

2. **Binary Search for Large Files**
   - Files >10MB use binary search to find date range quickly
   - Avoids scanning entire file

3. **Lightweight JSON Decoding**
   - `LightEntry` struct decodes only required fields (type, message, timestamp)
   - Skips unnecessary fields (sessionId, uuid, cwd, version, etc.)
   - ~3x faster than full `ConversationEntry` decoding

**Benchmark results (2026-01-22, 10 projects):**
- Original: 14,062ms
- With date index: 5,431ms (2.6x faster)
- With all optimizations: 1,702ms (8.3x faster)

### Statistics (getQuickStatistics)

- Uses `StatsEntry` lightweight decoder (even lighter than `LightEntry`)
- Binary search for large files
- Results cached for past dates (~0.3ms on cache hit)

### Caches

- **Date Index** (`~/Library/Caches/CCDiary/date_index_v2.json`): Maps dates to files containing that date
- **Statistics Cache** (`~/Library/Caches/CCDiary/statistics/`): Cached stats for past dates

## Benchmark Tool

A CLI benchmark tool is available for performance testing:

```bash
# Build
xcodebuild -scheme benchmark -configuration Release -derivedDataPath build build

# Run
./build/Build/Products/Release/benchmark 2026-01-22
```

## Slack Posting

- Bot token storage (in priority order): `SLACK_BOT_TOKEN` env, then Keychain service `sh.saqoo.CCDiary.slack-bot-token`. Token must start with `xoxb-` (user `xoxp-` and app `xapp-` tokens are rejected).
- Default private posting channel for Saqoosha: `C033F6U7147` (override with `--slack-channel`, `CCDIARY_SLACK_CHANNEL`, or `SLACK_CHANNEL_ID`).
- Invite the bot to the target channel before posting.
- Daily posting runs as LaunchAgent `sh.saqoo.CCDiary.daily` at 04:00 in the system's local time zone (JST on Saqoosha's Mac).
- Logs: `~/Library/Logs/CCDiary/daily.out.log` and `~/Library/Logs/CCDiary/daily.err.log`.
- Install/uninstall:

```bash
scripts/install-daily-launch-agent.sh
scripts/uninstall-daily-launch-agent.sh
```

- CLI posting example:

```bash
./build/Build/Products/Release/ccdiary-cli generate --yesterday --provider gemini --skip-existing --post-slack
# --slack-channel implies --post-slack:
./build/Build/Products/Release/ccdiary-cli generate --yesterday --slack-channel C0XXXXXXXXX
```

### Secrets resolution (env → file → Keychain)

`ccdiary-cli` resolves every secret in this order: process env, then a file at
`~/.config/ccdiary/secrets` (override with `CCDIARY_SECRETS_FILE`), then
Keychain. The file uses simple `KEY=value` lines (matching the env var
names) and should be `chmod 600`. Use it for the LaunchAgent so launchd
never has to ask for Keychain access (the ACL invalidates on every Release
rebuild because the binary's ad-hoc signature changes).

```bash
mkdir -p ~/.config/ccdiary
cat > ~/.config/ccdiary/secrets <<'EOF'
SLACK_BOT_TOKEN=xoxb-...
GEMINI_API_KEY=...
ANTHROPIC_API_KEY=...
OPENAI_API_KEY=...
CCDIARY_CLOUD_TOKEN=...
CCDIARY_CLOUD_ENDPOINT=https://ccdiary.saqoo.sh
EOF
chmod 600 ~/.config/ccdiary/secrets
```

### One-time setup

1. Create a Slack app, give it `chat:write` (and `chat:write.public` if posting to public channels), install to your workspace, and copy the bot token.
2. Store the token. Two options:
   - **Recommended for launchd**: write it to `~/.config/ccdiary/secrets` (see above). No Keychain prompts at 04:00.
   - **GUI app fallback**: keep it in Keychain — the GUI app stores tokens here automatically. The CLI only reaches for Keychain if env and the secrets file don't have it, so each Release rebuild can re-trigger the macOS prompt.
   ```bash
   # Keychain path (only useful for the GUI app or interactive CLI use):
   security add-generic-password -s sh.saqoo.CCDiary.slack-bot-token -a "$USER" -w xoxb-...
   ```
3. Invite the bot to the private channel: `/invite @your-bot` from inside Slack.
4. Smoke test the LaunchAgent right after install:
   ```bash
   launchctl kickstart -k gui/$(id -u)/sh.saqoo.CCDiary.daily
   tail -f ~/Library/Logs/CCDiary/daily.err.log
   ```

### Caveats

- The committed plist is a template (`@CCDIARY_BIN@`, `@LOG_DIR@`). The install script renders it to `~/Library/LaunchAgents/sh.saqoo.CCDiary.daily.plist` with absolute paths at install time — never commit the rendered version.
- `defaultSlackChannel` in [main.swift](Tools/CCDiaryCLI/main.swift) is a personal default. Forks should change it or rely on `--slack-channel` / `CCDIARY_SLACK_CHANNEL`.
- `--skip-existing` skips the Slack post too when a diary already exists for that date.
- `--force` and `--skip-existing` are mutually exclusive (rejected at parse time).
- Diaries are posted as Block Kit (header + section + context blocks) so Slack mrkdwn renders them cleanly. Sections beyond Slack's 50-block ceiling are dropped and a `:warning: Truncated to fit Slack limits.` context block is appended; the CLI also prints a warning to stderr.

## Cloud Archive (`web/`)

The Astro + Cloudflare Workers app under [`web/`](web/) mirrors every generated diary into D1 and presents a calendar + stats heatmap at `https://ccdiary.saqoo.sh`. Browser auth is a single password at `/login` (secrets `CCDIARY_SITE_PASSWORD` + `CCDIARY_SESSION_SECRET`); diary pages and `GET /api/diaries` need that session cookie. `POST /api/diaries` uses the ingest bearer token only.

- Endpoint storage (priority): `--cloud-endpoint URL` → `CCDIARY_CLOUD_ENDPOINT` env → Keychain `sh.saqoo.CCDiary.cloud-endpoint`
- Token storage (priority): `CCDIARY_CLOUD_TOKEN` env → Keychain `sh.saqoo.CCDiary.cloud-token`
- D1 schema lives at [web/schema.sql](web/schema.sql). Re-run with `bun run db:apply:remote` after schema changes (CREATEs are idempotent; FTS triggers are dropped + recreated).
- Stats payload is derived from `DayStatistics` in [CloudIngestService.swift](Sources/CCDiary/Services/CloudIngestService.swift): sessions, messages, project_count, active_minutes, peak_hour, top_project, plus per-source (`claudeCode` / `cursor` / `codex`) breakdown and full `ProjectSummary[]`.
- `--post-cloud` flag mirrors `--post-slack`: same skip rules under `--skip-existing`, same Keychain pattern. `--cloud-endpoint URL` implies `--post-cloud`.
- Backfill historical diaries with `ccdiary-cli sync-cloud [--from YYYY-MM-DD] [--to YYYY-MM-DD]`. Pulls `DayStatistics` from `StatisticsCache` when available.
- Local dev: `cd web && bun install && bun run db:apply:local && bun run dev` (server at `localhost:4321`). Use `dev-local-token` from `.dev.vars.example` for local POSTs.
- Full deploy runbook: [docs/WEB_DEPLOYMENT.md](docs/WEB_DEPLOYMENT.md).
