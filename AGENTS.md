# Development Guide for ccdiary

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
xcodebuild -scheme ccdiary -configuration Debug -derivedDataPath build build

# Run
open build/Build/Products/Debug/ccdiary.app
```

### 2. Kill running app before rebuild

```bash
pkill -f ccdiary
```

### 3. Quick iteration

```bash
pkill -f ccdiary; xcodebuild -scheme ccdiary -configuration Debug -derivedDataPath build build 2>&1 | tail -5 && open build/Build/Products/Debug/ccdiary.app
```

## Key Points

- **Always use `xcodebuild`** for building, not `swift build` (app requires proper signing and bundling)
- **Run `xcodegen generate`** after adding new source files
- Build output goes to `build/Build/Products/Debug/`
- Statistics cache stored in `~/Library/Caches/ccdiary/statistics/`

## Debugging

### Viewing logs

Use `logger.notice` (not `logger.info`) for logs that need to be persisted and visible:

```swift
import os.log
private let logger = Logger(subsystem: "ccdiary", category: "MyService")
logger.notice("Message here")
```

View logs with:

```bash
/usr/bin/log show --predicate 'subsystem == "ccdiary"' --last 30s
```

### Testing with clean state

**Important:** Always kill the app by PID, not by pattern matching (to avoid killing other processes):

```bash
# Find the PID
ps aux | grep ccdiary.app | grep -v grep

# Kill by PID
kill <PID>

# Clear all caches
rm -rf ~/Library/Caches/ccdiary/

# Rebuild and run
xcodebuild -scheme ccdiary -configuration Debug -derivedDataPath build build 2>&1 | tail -3
open build/Build/Products/Debug/ccdiary.app
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

- `Sources/ccdiary/Models/` - Data models
- `Sources/ccdiary/Views/` - SwiftUI views
- `Sources/ccdiary/Services/` - Business logic and data access
  - `HistoryService` - Reads Claude Code history
  - `ConversationService` - Reads conversation JSONL files (with binary search optimization)
  - `AggregatorService` - Aggregates daily activity data
  - `StatisticsCache` - Caches statistics for past dates
  - `DiaryStorage` - Saves/loads diary entries
  - `ClaudeAPIService` - Generates diaries via Claude API

## Performance Optimizations

### Binary Search for Large Files

`ConversationService` uses binary search for JSONL files >10MB to quickly find date ranges:

- **Before**: 4090ms for dates with large files (87MB)
- **After**: ~480ms (8x faster)

Key implementation details:
- Files >10MB use `parseStatsFromLargeFile()` with binary search
- Files ≤10MB use full scan (fast enough)
- Binary search reads 1MB chunks to handle very long lines (some >256KB)
- Position 0 has special handling to read first line correctly

### Caches

- **Date Index** (`~/Library/Caches/ccdiary/date_index_v2.json`): Maps dates to files containing that date
- **Statistics Cache** (`~/Library/Caches/ccdiary/statistics/`): Cached stats for past dates
