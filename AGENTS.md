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
- **`xcodegen generate` reorders a line in `CCDiary.xcodeproj/project.pbxproj` non-deterministically.** The diff is byte-identical content at a different position — no semantic change. `install-daily-launch-agent.sh` runs xcodegen, so every install leaves this even when you changed nothing. **Check the diff before discarding it:** `jj restore --from main CCDiary.xcodeproj/project.pbxproj` reverts the *whole file*, so if you also added a source file, that restore silently un-registers it. Only reach for it once `jj diff CCDiary.xcodeproj/project.pbxproj` shows nothing but the reorder.

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

### Automated session exclusion

Claude Code sessions launched by background automation are excluded from
diaries, statistics, and the calendar — they are not the user's own activity.
Detection probes the first 128 KB of a session JSONL for either marker
(neither subsumes the other):

- **Scheduled tasks / cron routines** (idea ported from Canopy): a
  `queue-operation` line with `operation == "enqueue"` whose `content` embeds
  `<scheduled-task ...>`. Their `entrypoint` is the spawning app
  (e.g. `claude-desktop`), so the entrypoint check alone can't catch them.
- **Headless SDK / `claude -p` runs**: top-level `entrypoint == "sdk-cli"`
  (interactive sessions are `claude-vscode` / `claude-desktop` / `cli`) **and**
  at most one distinct user prompt in the whole file. The prompt-count guard
  matters: some surfaces (e.g. managed agents driven from another device)
  report `sdk-cli` while a human is genuinely conversing — observed bots all
  send exactly one templated prompt, humans send several.

Both checks are confirmed by per-line JSON decode so sessions merely
*mentioning* a marker don't false-positive. Subagent transcripts
(`<project>/<sessionId>/subagents/agent-*.jsonl`) inherit the verdict of their
parent session file. The filter is unconditional and lives in
`ConversationService` (`isAutomatedSessionFile` / `filterAutomatedSessionFiles`),
applied at all three JSONL discovery sites: `buildFullDateIndex` (automated
files are indexed with an empty date set — so **changing detection logic
requires bumping the date-index version**), `findConversationFiles`, and
`findConversationFilesForDateRange`. Note: cached statistics computed before
this feature still include automated sessions; clear
`~/Library/Caches/CCDiary/statistics/` to recompute.

#### Substring exclusion (escape hatch)

Some automated sources don't hit either marker but still surface in the
aggregator as zero-message phantom projects. `AggregateOptions.excludeProjectSubstrings`
drops any project whose path **or** name contains one of the configured
substrings (case-insensitive). The CLI exposes this via `--exclude-project NAME`
(repeatable) and always merges in the always-on defaults from
`CLIOptions.defaultExcludeSubstrings` in [Tools/CCDiaryCLI/main.swift](Tools/CCDiaryCLI/main.swift)
unless `--no-default-exclude` is passed:

- `observer-sessions` — `claude-mem-observer-sessions` wrote pathologically
  large JSONLs (1,056 files, 5.0 GB, up to 17 MB each) with no useful diary
  content: they were an observer bot's synthetic sessions, not Saqoosha's
  conversations. **claude-mem was decommissioned 2026-08-16 and those JSONLs
  deleted**, so nothing matches this today. Kept anyway — the entry costs
  nothing and still applies if an old machine or a restored backup surfaces
  them.
- `claude-mem` — same family, same status.
- `ClaudeProbe` — **CodexBar.app** (`com.steipete.codexbar`, Peter Steipete's
  menu-bar status app) repeatedly spawns `claude` CLI with `cwd =
  ~/Library/Application Support/CodexBar/ClaudeProbe` and slash commands like
  `/usage` / `/status` (thousands of entries in `~/.claude/history.jsonl`).
  These don't persist transcripts in `~/.claude/projects/`, but the project
  name still leaks into stats and the diary with `messageCount: 0`. Marker
  checks miss it because there's no JSONL to probe.

When you spot a new automated-but-marker-less project polluting the diary,
adding its substring here is the fix. Past stats cache entries are NOT
recomputed automatically — `rm -rf ~/Library/Caches/CCDiary/statistics/` after
changing the list, then regenerate affected dates with `--force`.

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
- Returns `QuickStatisticsResult` (`.idle` / `.measured` / `.unavailable`) so
  callers cannot treat a verified zero and a failed read as the same value;
  `.unavailable` must never become a published zero

### Caches

- **Date Index** (`~/Library/Caches/CCDiary/date_index_v3.json`): Maps dates to files containing that date (v3: automated sessions excluded)
- **Statistics Cache** (`~/Library/Caches/CCDiary/statistics/`): Cached stats for past dates
- **Cursor Bubble Index** (`~/Library/Caches/CCDiary/cursor_bubble_index_v4.json`): Maps dates to `cursorDiskKV` bubble keys

**Reference measurements for a Cursor index change** — one snapshot of one
machine (Saqoosha's MBP, 3.4 GB `state.vscdb`, 2026-08-16), not fixed
constants. `state.vscdb` grows with every Cursor session, so all of these drift
upward on their own; a different number proves nothing by itself. Use them the
only way they are valid: **measure before your change and after it, on the same
machine and the same DB**, and investigate a difference between those two.

| Probe | Cost |
|---|---|
| `SELECT MAX(rowid) … WHERE key LIKE 'bubbleId:%'` | 7 ms |
| `SELECT COUNT(*) … WHERE key LIKE 'bubbleId:%'` | 25 ms (92,578 rows) |
| Full index build | ~10 s |

The index held 85 dates / 19,008 bubbles at `maxRowid` 2,543,366 and
`dbBubbleRowCount` 92,578. The useful shape here is the *ratio*, which does not
drift: the two probes stay in the tens of milliseconds while a full build stays
around 10 s, so a probe that suddenly costs seconds means it stopped being a
seek.

For an end-to-end check, prefer a **past** date, whose inputs no longer change:
`ccdiary-cli generate --date 2026-08-14 --dry-run` read 2 projects / 174
messages from Cursor. That number is stable as long as those chats are not
deleted — which the deletion trigger above is designed to notice.

#### Cursor bubble index is incremental (v4)

`state.vscdb` grows without bound (3.4 GB observed, measured 2026-08-16). v1
re-scanned every `bubbleId:%` row whenever the DB's mtime changed — i.e. every
day Cursor was used — costing ~10s warm (measured 2026-08-16) and much more
under load. v2/v3/v4 store a `maxRowid` watermark and only scan
`rowid >= watermark`, which SQLite serves as
`SEARCH cursorDiskKV USING INTEGER PRIMARY KEY (rowid>?)` — a seek, not a scan
(SQLite renders a `>=` bind as `(rowid>?)` in `EXPLAIN QUERY PLAN`).
The `>=` (not `>`) is deliberate overlap covering rowid reuse at exactly the
watermark; the per-date `Set` dedupe in `mergeIndex` absorbs the one redundant
row.

This is safe because `cursorDiskKV` is declared
`key TEXT UNIQUE ON CONFLICT REPLACE`: rewriting a bubble deletes the old row
and re-inserts it at a **new, higher** rowid, so edits reappear above the
watermark rather than hiding below it. The index derives the date from
`createdAt` **and** membership from the byte pre-filter (`"type":1`/`"type":2`
present, `"text":""` absent). Most excluded rows are permanently empty
tool/thinking bubbles (not pending fill-in); a genuine message fill-in
re-enters above the watermark via REPLACE. `createdAt` itself is immutable, so
a re-seen bubble maps to the same date and is de-duplicated on merge. A full
rescan is forced when any of: the index has never been built (`hasBuilt`, not
`maxRowid == 0`); `MAX(rowid)` went **backwards** (vacuum/reset); or the
unfiltered `bubbleId:%` row count decreased (net deletion). Known limitation:
a DB replaced with one whose bubble row count is not lower and whose
`MAX(rowid)` did not regress keeps serving a stale index until one of those
three fires. Residual: a deletion exactly compensated by an equal or greater
number of new rows between two runs still leaves stale keys until the next net
deletion or rowid regression.

The biggest known residual, left open deliberately: the incremental design
rests on Cursor rewriting bubbles via `INSERT … ON CONFLICT REPLACE` (new
higher rowid), verified experimentally. A plain `UPDATE … WHERE key = ?` would
preserve the rowid, and since the watermark advances past pre-filtered rows,
such bubbles would be excluded permanently with none of the three triggers
noticing. v1's unconditional rescan absorbed this class invisibly; v4 does
not. No periodic forced rescan was added — `rm -rf
~/Library/Caches/CCDiary/cursor_bubble_index_v4.json` is the manual recovery.

#### A timed-out reader must never be cached as an under-count

`AggregatorService.runWithTimeout` degrades a timeout to an empty result.
Precisely: a day where *every* source came back empty used to be ambiguous —
`getQuickStatistics` returned `nil` for both verified idle and "nothing could
be read", so callers could not tell them apart. It now returns
`QuickStatisticsResult`: `.idle` (every enabled reader completed, found
nothing — a real zero, safe to publish or seed a merge with),
`.measured(DayStatistics)` (has data; `incompleteSources` non-empty means a
lower bound), or `.unavailable(sources:)` (nothing read and at least one
reader failed — must never become a published zero). The damage to avoid was
never an all-zero cache entry from a fully-failed day (that path returned
before the cache write); it was the **partial** case: one reader times out
while another returns data, and the resulting under-count was written straight
into the Statistics Cache, where it served that wrong answer for that date
forever after. Readers report which source was cut short
(`DayStatistics.incompleteSources` / `DailyActivity.incompleteSources` —
`DayStatistics` deliberately omits the field from `CodingKeys` so it never
reaches disk or the cloud; `DailyActivity` is `Sendable` only and is never
serialized), and `getQuickStatistics` skips the cache write when anything is
incomplete. Every reader timeout/failure warning names the date, on stderr as
well as os_log — the AI-generation warnings around diary retries do not, and are
outside this claim. That suppression
covers the **local statistics cache only**; `--post-cloud`, `push-stats`, and
`sync-cloud --compute-stats` still upload under-counted numbers with a stderr
warning (and a peer Mac merges them as truth). Asymmetry after the merge
refusal narrowing: `generate --merge-cloud-stats` refuses only when there is
no local measurement at all (throw or `.unavailable`), leaving the
server's existing columns untouched; the other upload paths above still send
whatever they have with a warning.

**Statistics cache entries written before this change may still hold unverified
zeros.** `rm -rf ~/Library/Caches/CCDiary/statistics/` to recompute.

##### Which reader failures actually set `incompleteSources`

The `.idle` / `.unavailable` split is only as good as the readers' honesty, and
they are not uniformly honest. Verify before assuming either way — this has been
gotten wrong twice, in both directions.

- **DB-open failures throw, and are reported correctly.** Cursor's
  `getActivityForDate` opens with `guard isAvailable() else { return [] }`, but
  `isAvailable()` is a bare `fileExists`, so that guard only catches *Cursor not
  installed* — where empty is the right answer. A DB that exists but cannot be
  opened (TCC denial, corruption, lock) falls through to
  `getGlobalActivityForDate` → `try openGlobalDB()`, throws, and
  `runWithTimeout` marks the source incomplete.
- **Directory listings swallow.** `CodexActivityReader.rolloutFiles(in:)` and
  `CursorService.getAllWorkspaces()` both do
  `guard let contents = try? FileManager.default.contentsOfDirectory(…) else { return [] }`.
  A present-but-unreadable directory yields zero files with no throw and no log,
  so the source reports "nothing" and the day reads as idle or as a complete
  measurement that is silently short one source. Codex is the exposed one —
  Cursor's legacy workspace path is only consulted after the global read already
  came back empty. Tracked in #25.
- `ClaudeCodeActivityReader` does not have this shape (checked): its bare
  `return []` is a genuine "no matching project groups", and its per-file work
  runs in a `withThrowingTaskGroup` that propagates.

Also worth knowing: `getQuickStatistics` is declared `async throws` but its body
contains no `try` at all, so it cannot currently throw. The `catch` blocks and
`statsComputeFailed` flags in `runGenerate` / `runSyncCloud` are therefore
unreachable today. They are kept deliberately — deleting them would silently
reintroduce the seed-a-zero bug the day the function starts throwing.

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

### Unattended runs: storage location, code signing & TCC

The 04:00 LaunchAgent runs headless — nothing can dismiss a permission dialog, so any
TCC prompt would silently stall the run. Two things keep it dialog-free:

- **Diaries live outside `~/Documents`.** `DiaryStorage` defaults to
  `~/Library/Application Support/CCDiary` (not the TCC-protected Documents folder).
  Older locations (`~/Documents/CCDiary`, then `~/Documents/ccdiary`) auto-migrate on
  first run and their now-empty trees are removed. A custom path set in the GUI still wins.
- **The launchd-invoked `ccdiary-cli` binary lives outside `~/Documents` too —
  do NOT point the LaunchAgent plist at the build path under `~/Documents`,
  that re-arms the failure mode below.** `install-daily-launch-agent.sh` stages
  the freshly built binary from `build/Build/Products/Release/ccdiary-cli`
  (inside the repo, which itself sits under `~/Documents/repos/…` on Saqoosha's
  Mac) into a temp file under `~/Library/Application Support/CCDiary/bin/`,
  signs that staged copy, then atomically `mv`s it to
  `~/Library/Application Support/CCDiary/bin/ccdiary-cli`, and points both
  LaunchAgent plists at the installed path. The repo / build artifacts can
  stay in Documents; only the binary launchd actually `exec()`s is moved. The
  shared install location lives in [scripts/_launchd-paths.sh](scripts/_launchd-paths.sh)
  so install and uninstall can never drift. Reason: empirically observed on
  Saqoosha's Mac Studio — whenever Claude Code (or anything else) triggers a
  fresh Documents TCC prompt for the user session, the dialog can sit pending
  for hours, and while it's pending the 04:00/04:05 launchd fires don't run on
  time if the binary they point at lives under `~/Documents`. The exact gating
  layer (TCC, exec policy, the pending dialog blocking launchd's launch path,
  or something else) isn't proven, but the symptom is consistent: on days with
  no claude-CLI update the post lands at 04:05; on days with one, it lands only
  after Saqoosha dismisses the Documents dialog (often much later). Pointing
  launchd at a copy under `~/Library/Application Support/CCDiary/bin/`
  eliminates the symptom because that path doesn't sit behind the Documents
  consent prompt.
- **`ccdiary-cli` is signed with a stable Developer ID.** The plain Xcode build is
  ad-hoc signed, whose Designated Requirement is CDHash-based and changes on every
  rebuild — that invalidates TCC (Full Disk Access) and Keychain grants, so a rebuild
  (e.g. triggered after a Claude Code auto-update) would re-trigger prompts.
  `install-daily-launch-agent.sh` re-signs with `Developer ID Application: Whatever Co.
  (G5G54TCH8W)` so the requirement stays constant across rebuilds. Override via
  `CCDIARY_SIGN_IDENTITY`; forks without a Developer ID can use any persistent
  self-signed code-signing certificate.
- **`install-daily-launch-agent.sh` must be run from the machine's own GUI
  session — it cannot be driven over SSH.** `codesign` with the Developer ID
  identity fails there with `errSecInternalComponent`, because an SSH session's
  login keychain is locked and the private key is unreachable. The script then
  refuses to install (correctly — an ad-hoc-signed agent would reset TCC and
  Keychain grants on every rebuild) and leaves a `ccdiary-cli.XXXXXX` temp file
  in the install dir that it does not clean up; delete it by hand. Do NOT try to
  work around this with `security unlock-keychain`. Deploying to the other Mac
  means: update the repo and build over SSH if you like, then run the install
  script in a terminal on that machine.

Full Disk Access is **not** required now that Documents is avoided. If you ever do hit a
TCC prompt (a future feature reading a protected location), grant it once via
System Settings → Privacy & Security → Full Disk Access (drag in the `ccdiary-cli`
binary). Because the signature is now stable, that grant persists across rebuilds —
with ad-hoc signing it reset every time.

### Secrets resolution (env → file → Keychain)

`ccdiary-cli` resolves every secret in this order: process env, then a file at
`~/.config/ccdiary/secrets` (override with `CCDIARY_SECRETS_FILE`), then
Keychain. The file uses simple `KEY=value` lines (matching the env var
names) and should be `chmod 600`. Use it for the LaunchAgent so launchd never
has to ask for Keychain access — even with the stable Developer ID signing
above (which keeps the Keychain ACL valid across rebuilds), the secrets file
is still preferred because it avoids any Keychain prompt at all and works on
forks that haven't set up a signing identity yet.

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

The Astro + Cloudflare Workers app under [`web/`](web/) mirrors every generated diary into D1 and presents a calendar + stats heatmap at `https://ccdiary.saqoo.sh`. Browser auth is a single password at `/login` (secrets `CCDIARY_SITE_PASSWORD` + `CCDIARY_SESSION_SECRET`), and that session cookie gates the diary **pages**. The API is separate: middleware puts `/api/diaries` and `/api/host-stats` behind the ingest bearer token for every method, so the cookie does not open them.

- Endpoint storage (priority): `--cloud-endpoint URL` → `CCDIARY_CLOUD_ENDPOINT` env → Keychain `sh.saqoo.CCDiary.cloud-endpoint`
- Token storage (priority): `CCDIARY_CLOUD_TOKEN` env → Keychain `sh.saqoo.CCDiary.cloud-token`
- D1 schema lives at [web/schema.sql](web/schema.sql). Re-run with `bun run db:apply:remote` after schema changes (CREATEs are idempotent; FTS triggers are dropped + recreated).
- Stats payload is derived from `DayStatistics` in [CloudIngestService.swift](Sources/CCDiary/Services/CloudIngestService.swift): sessions, messages, project_count, active_minutes, peak_hour, top_project, plus per-source (`claudeCode` / `cursor` / `codex`) breakdown and full `ProjectSummary[]`.
- `--post-cloud` flag mirrors `--post-slack`: same skip rules under `--skip-existing`, same Keychain pattern. `--cloud-endpoint URL` implies `--post-cloud`.
- Backfill historical diaries with `ccdiary-cli sync-cloud [--from YYYY-MM-DD] [--to YYYY-MM-DD]`. Pulls `DayStatistics` from `StatisticsCache` when available.
- `--merge-cloud-stats` works on **both** `generate` and `sync-cloud`. On `generate` it merges other Macs' host-stats into the diary prose *and* the uploaded `DayStatistics`; on `sync-cloud` it exists to repair an already-ingested row without re-running AI generation:

  ```bash
  ccdiary-cli sync-cloud --from 2026-08-15 --to 2026-08-15 --merge-cloud-stats --compute-stats
  ```

  **Trap (fixed 2026-08-16, observed live on 2026-08-15):** the merge is seeded
  with `DayStatistics.empty(for:)` when the local Mac was idle. Previously the
  code bound `if ..., let localStats = stats`, and `getQuickStatistics` returned
  a collapsed `nil` on a zero-activity day — so on any day the primary Mac did
  nothing, the whole merge was skipped and the cloud row landed with 0 sessions
  / 0 messages even though the prose was correctly built from remote digests.
  Prose merging (`mergeDailyActivity`) and stats merging (`mergeDayStatistics`)
  are separate paths; fixing one does not fix the other. Idle is now
  `QuickStatisticsResult.idle` (distinct from `.unavailable`); do not seed
  `.empty` from `.unavailable`.
- **Omitting the `stats` block preserves existing columns only on UPDATE, never on INSERT.** `upsertDiary` gates every stats column on a `hasStats` sentinel (`CASE WHEN ?16 = 1 THEN excluded.x ELSE diaries.x END`) — but that lives solely in the `ON CONFLICT(date) DO UPDATE` arm. The INSERT arm binds `stats?.sessions ?? 0`, `stats?.messages ?? 0`, `stats?.project_count ?? 0`. So withholding stats to avoid publishing an unverified number still writes zeros on a **first-time** ingest for that date — which the 04:00 `generate --yesterday` run always is. The CLI warns when it does this; the row is still wrong. Tracked in #27.
- Endpoint auth, which matters when debugging from outside the browser — [web/src/middleware.ts](web/src/middleware.ts) gates `/api/diaries` and `/api/host-stats` on `checkBearer` for **every** method, so a browser session cookie gets 401 on both no matter how you're logged in; query them with `Authorization: Bearer $CCDIARY_CLOUD_TOKEN`. `GET /api/stats` and `/stats.svg` are **public**. Diary pages are the cookie-gated surface: `/<date>` returns **404 when unauthenticated**, so a 404 there means "not logged in", not "no diary for that date". The heatmap in `/api/stats` reads the `diaries` table only — `host_stats` rows never appear in it.
- Local dev: `cd web && bun install && bun run db:apply:local && bun run dev` (server at `localhost:4321`). Use `dev-local-token` from `.dev.vars.example` for local POSTs.
- Full deploy runbook: [docs/WEB_DEPLOYMENT.md](docs/WEB_DEPLOYMENT.md).
</claude-mem-context>