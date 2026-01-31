# Performance Optimization Journey

This document describes the performance optimizations applied to CCDiary's statistics calculation.

## Problem Statement

Loading daily statistics was slow, especially for dates with many projects and conversation files.

**Initial Performance (Jan 20, 9 projects, 1235 messages):**
- Sequential processing: ~19 seconds
- Unacceptable for interactive calendar UI

## Optimization Techniques Applied

### 1. Parallel Project Processing

**Before:** Projects processed sequentially
**After:** Using Swift's `TaskGroup` to process projects concurrently

```swift
let results = try await withThrowingTaskGroup(of: ProjectResult?.self) { group in
    for (projectPath, entries) in projectGroups {
        group.addTask {
            // Process each project in parallel
        }
    }
    // Collect results
}
```

**Impact:** ~30% improvement

### 2. Quick Date Range Check

Instead of reading entire files, read only first and last 4KB to determine if file's date range overlaps with target date.

```swift
private static func getFileDateRangeQuick(fileURL: URL) -> ClosedRange<Date>? {
    guard let fileHandle = FileHandle(forReadingAtPath: fileURL.path) else { return nil }
    defer { try? fileHandle.close() }

    // Read first 4KB for first timestamp
    guard let headData = try? fileHandle.read(upToCount: 4096) else { return nil }
    // Extract timestamp from first line...

    // Seek to end, read last 4KB for last timestamp
    try? fileHandle.seek(toOffset: endOffset - 4096)
    guard let tailData = try? fileHandle.read(upToCount: 4096) else { return nil }
    // Extract timestamp from last line...

    return firstDate...lastDate
}
```

**Impact:** Skip ~90% of files without full read

### 3. Persistent File Date Cache

Cache file date ranges to disk to avoid repeated quick checks.

```swift
private actor FileDateCache {
    private var cache: [String: ClosedRange<Date>] = [:]
    private var fileModTimes: [String: Date] = [:]

    func get(for path: String, modTime: Date) -> ClosedRange<Date>?
    func set(for path: String, modTime: Date, range: ClosedRange<Date>)
    func saveToDiskIfNeeded()
}
```

**Impact:** Faster subsequent loads

### 4. Lightweight Stats Decoder

For statistics, we don't need full `ConversationEntry` decoding. Created minimal struct:

```swift
private struct StatsEntry: Decodable {
    let type: String
    let message: StatsMessage?
    let isMeta: Bool?

    struct StatsMessage: Decodable {
        let role: String
        let content: StatsContent  // Only extracts text length
    }

    var isValidForStats: Bool { ... }
    var textLength: Int { ... }
}
```

**Impact:** ~10% faster JSON decoding

### 5. Nonisolated Static Functions (KEY OPTIMIZATION)

**The biggest improvement came from removing actor isolation for file I/O.**

**Before:** File reading through actor methods - serialized execution
```swift
actor ConversationService {
    func readStatsForDateRange(...) async throws -> (Int, Int) {
        // All calls serialize through actor
    }
}
```

**After:** Nonisolated static function - true parallel execution
```swift
actor ConversationService {
    nonisolated static func readStatsFromFileFast(
        _ fileURL: URL,
        datePrefix: String,
        start: Date,
        end: Date
    ) -> (messageCount: Int, characterCount: Int) {
        // Can run truly in parallel across all CPU cores
    }
}
```

**Impact:** 3x improvement (6.2s → 2s)

### 6. Bulk Read vs Streaming

Tested streaming (chunk-by-chunk) vs bulk read. **Bulk read is faster** for this use case.

```swift
// Bulk read - FASTER
let data = try Data(contentsOf: fileURL)
let text = String(data: data, encoding: .utf8)
let lines = text.split(separator: "\n")

// Streaming - SLOWER (19s vs 6s)
// Overhead of buffer management outweighs memory savings
```

### 7. Fast Date Prefix Matching

Instead of parsing full timestamps, do quick string prefix check:

```swift
@inline(__always)
private static func lineMatchesDate(_ line: String, datePrefix: String) -> Bool {
    guard let range = line.range(of: "\"timestamp\":\"") else { return false }
    return line[range.upperBound...].hasPrefix(datePrefix)
}
```

### 8. Binary Search for Large Files (Latest Optimization)

For very large files (>10MB), we now use binary search to find the target date range:

```swift
private nonisolated static func parseStatsFromLargeFile(
    _ fileURL: URL,
    datePrefix: String,
    fileSize: UInt64
) -> (messageCount: Int, characterCount: Int) {
    // 1. Binary search to find approximate start position
    let startOffset = binarySearchForDate(fileHandle, datePrefix, fileSize)

    // 2. Seek with safety margin (500KB before found position)
    let safeStart = startOffset > 500_000 ? startOffset - 500_000 : 0

    // 3. Read in 4MB chunks from found position
    while true {
        let chunk = try fileHandle.read(upToCount: 4 * 1024 * 1024)
        // Process lines, stop when date passes
    }
}
```

**Key implementation details:**

1. **1MB chunk for line reading**: Some JSONL lines can exceed 256KB, so we read 1MB chunks in `readDateAtPosition()` to ensure we capture complete lines.

2. **Position 0 special handling**: When binary search points to position 0, we read the first line directly instead of skipping it.

3. **Two-phase binary search**:
   - Phase 1: Find any occurrence of target date
   - Phase 2: Find left boundary (first occurrence)
   - Phase 3: Linear scan for exact first line

**Impact:** For dates with 87MB files: 4090ms → **480ms** (8.5x faster)

## Results Summary

| Scenario | Before | After | Improvement |
|----------|--------|-------|-------------|
| Jan 20 (9 projects, 1235 msgs) | 19s | **2s** | 90% faster |
| **Jan 22 (10 projects, 1027 msgs, 87MB file)** | 4090ms | **480ms** | 8.5x faster |
| Jan 23 (3 projects, 780 msgs) | 2.5s | **1.1s** | 56% faster |
| Cached load | N/A | **0.2ms** | Instant |

## Key Lessons

1. **Actor isolation can hurt parallelism** - Use `nonisolated` for CPU-bound work
2. **Bulk I/O often beats streaming** - Unless memory is critical
3. **Skip early, skip often** - Quick checks to avoid full processing
4. **Decode only what you need** - Lightweight structs for specific use cases
5. **Measure before optimizing** - Logging with timestamps identified real bottlenecks
6. **Binary search for large files** - O(log n) position finding vs O(n) full scan
7. **Handle edge cases carefully** - Long lines (>256KB) and file boundaries need special handling

## Architecture Overview

```
AggregatorService (actor)
    └── getQuickStatistics()
            │
            ├── HistoryService.readHistory() [cached]
            │
            └── TaskGroup (parallel per project)
                    │
                    └── TaskGroup (parallel per file)
                            │
                            └── ConversationService.readStatsFromFileFast() [nonisolated static]
                                    │
                                    ├── Quick date range check (file metadata)
                                    │
                                    └── parseStatsFromFile()
                                            │
                                            ├── Files ≤10MB: Bulk read + scan
                                            │
                                            └── Files >10MB: parseStatsFromLargeFile()
                                                    │
                                                    ├── Binary search for date position
                                                    ├── Chunked reading (4MB chunks)
                                                    ├── Date prefix filter
                                                    └── Lightweight JSON decode
```
