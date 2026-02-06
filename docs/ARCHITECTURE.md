# CCDiary - Architecture

## Overview

CCDiary is a macOS app that analyzes Claude Code, Cursor, and Codex conversation history and generates daily work diaries using AI (Claude API, Gemini API, or OpenAI API).

```text
┌────────────────────────────────────────────────────────────────────┐
│                        macOS App (SwiftUI)                         │
│                        CCDiaryApp.swift                            │
└────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌────────────────────────────────────────────────────────────────────┐
│                         ContentView                                │
│                    (DiaryViewModel @Observable)                    │
│                                                                    │
│  - Manages UI state                                                │
│  - Orchestrates data loading                                       │
│  - Handles user interactions                                       │
└────────────────────────────────────────────────────────────────────┘
          │              │              │              │
          ▼              ▼              ▼              ▼
┌────────────┐  ┌────────────┐  ┌────────────┐  ┌────────────────┐
│  History   │  │Conversation│  │ Aggregator │  │   DiaryStorage │
│  Service   │  │  Service   │  │  Service   │  │                │
│  (Actor)   │  │  (Actor)   │  │  (Actor)   │  │    (Actor)     │
└────────────┘  └────────────┘  └────────────┘  └────────────────┘
                                      │
                                      ▼
                            ┌─────────────────────┐
                            │ Shared AIAPIService │
                            │   Claude / Gemini   │
                            │      / OpenAI       │
                            └─────────────────────┘
```

## UI Architecture

### Views

```text
┌─────────────────────────────────────────────────────────────┐
│  HSplitView                                                 │
├───────────────────┬─────────────────────────────────────────┤
│  CalendarGridView │  RightPaneView                          │
│  (200-260px)      │  ┌───────────────────────────────────┐  │
│                   │  │ Header (Date + Inline Stats)      │  │
│  S M T W T F S    │  │ [projects] [sessions] [msgs]      │  │
│  ├───────────┤    │  ├───────────────────────────────────┤  │
│  │ 1  2  3  4│    │  │ Projects Section                  │  │
│  │ ...       │    │  │ [Project1] 14 msgs, 2h 15m       │  │
│  │ [23]      │    │  │ [Project2]  8 msgs, 1h 30m       │  │
│  │ ...       │    │  ├───────────────────────────────────┤  │
│  └───────────┘    │  │ Diary Markdown (WKWebView)        │  │
│                   │  │                                   │  │
│                   │  │ [Generate] or [Copy] button       │  │
│                   │  └───────────────────────────────────┘  │
└───────────────────┴─────────────────────────────────────────┘
```

### View Components

| View | File | Description |
|------|------|-------------|
| `ContentView` | Views/ContentView.swift | Main view with HSplitView layout |
| `CalendarGridView` | Views/CalendarGridView.swift | Scrollable calendar (from earliest activity to end of current month) |
| `RightPaneView` | Views/RightPaneView.swift | Header + projects + diary display |
| `SettingsView` | Views/SettingsView.swift | API key, model, directory settings |

### DiaryViewModel

Main view model managing all UI state.

```swift
@Observable @MainActor
final class DiaryViewModel {
    // Calendar state
    var datesWithActivity: Set<String>  // Dates with Claude Code/Cursor/Codex activity
    var datesWithDiary: Set<String>     // Dates with generated diary
    var selectedDate: Date

    // Current day data
    var currentDayStatistics: DayStatistics?
    var currentDiary: DiaryEntry?

    // Loading states
    var isLoadingInitial: Bool
    var isLoadingDate: Bool
    var isGenerating: Bool

    // Settings (synced with UserDefaults)
    var aiProvider: AIProvider
    var apiModel: String
    var geminiModel: String
    var openAIModel: String
    var diariesDirectoryPath: String
}
```

## Data Flow

### App Launch

```text
1. loadInitialData()
   ├── checkCursorPermission()
   ├── AggregatorService.buildDateIndex()
   ├── AggregatorService.getAllActivityDates()
   ├── DiaryStorage.loadAll()
   │   └── Scan diaries directory for *.md
   ├── Update datesWithActivity, datesWithDiary
   └── loadDataForDate(selectedDate)
```

### Date Selection

```text
2. loadDataForDate(date)
   ├── AggregatorService.getQuickStatistics(date)
   │   ├── Filter history by date
   │   ├── Group by project
   │   └── Return DayStatistics (no content)
   ├── DiaryStorage.load(dateString)
   │   └── Load {dateString}.md if exists
   └── Update currentDayStatistics, currentDiary
```

### Diary Generation

```text
3. generateDiary(date)
   ├── AggregatorService.aggregateForDate(date)
   │   ├── Read history.jsonl
   │   ├── Filter to target date
   │   ├── Group by project
   │   └── For each project:
   │       ├── Find conversation files
   │       ├── Filter by time range
   │       ├── Extract meaningful messages
   │       └── Truncate & limit messages
   ├── generateDiaryContent(activity, provider)
   │   ├── Resolve provider key from Keychain
   │   ├── Resolve provider service/model
   │   └── Call Claude/Gemini/OpenAI service
   │   ├── Build prompt with project data
   │   ├── Call AI provider
   │   └── Post-process markdown
   ├── DiaryStorage.save(entry)
   │   └── Write to {dateString}.md
   └── Update currentDiary, datesWithDiary
```

## Services (Actors)

All services are implemented as Swift Actors for thread-safe concurrent access.

### HistoryService

Reads Claude Code input history.

| Method | Description |
|--------|-------------|
| `readHistory()` | Parse ~/.claude/history.jsonl |
| `filterByDate(entries, date)` | Filter entries to specific day |
| `groupByProject(entries)` | Group by project path |

### ConversationService

Reads detailed conversation logs.

| Method | Description |
|--------|-------------|
| `encodeProjectPath(path)` | Convert `/a/b/c` to `-a-b-c` |
| `findConversationFiles(project)` | Find all .jsonl files for project |
| `readConversation(file)` | Parse conversation file |
| `filterByTimeRange(conversations, range)` | Filter by timestamp |
| `filterMeaningfulMessages(entries)` | Remove meta/snapshot entries |
| `extractTextContent(entry)` | Extract text from content blocks |

### CursorService

Reads Cursor chat history from SQLite database.

| Method | Description |
|--------|-------------|
| `getActivityForDate(date)` | Get all Cursor activity for a date |
| `getAllDatesWithMessages()` | Get all dates with Cursor messages |
| `buildDateIndexIfNeeded()` | Build date index for fast lookups |

### CodexService

Reads Codex CLI/App chat history from session files.

| Method | Description |
|--------|-------------|
| `getActivityForDate(date)` | Get all Codex activity for a date |
| `getAllDatesWithMessages()` | Get all dates with Codex messages |
| `buildDateIndexIfNeeded()` | Build date index for fast lookups |

### AggregatorService

Orchestrates data collection from Claude Code, Cursor, and Codex.

| Method | Description |
|--------|-------------|
| `aggregateForDate(date)` | Full aggregation with conversation content |
| `getQuickStatistics(date)` | Fast stats without reading conversation content |
| `getAllActivityDates()` | Get all dates with activity from all sources |

### AI Services

Multiple AI providers are supported for diary generation:

| Service | Description |
|---------|-------------|
| `AIAPIService` | Common protocol used by all providers |
| `AIAPIError` | Shared provider-aware error model |
| `ClaudeAPIService` | Direct Anthropic API calls |
| `GeminiAPIService` | Google Gemini API |
| `OpenAIAPIService` | OpenAI Responses API calls |

**Provider Selection:**

Users can choose their preferred provider in Settings.

Current model presets in Settings:
- Claude: Haiku 4.5 / Sonnet 4.5 / Opus 4.5
- Gemini: 2.5 Flash / 2.5 Pro / 3 Flash
- OpenAI: GPT-5.2 / GPT-5 mini / GPT-5 nano

**Common Prompt:**

- Generate diary in Japanese
- Focus on accomplishments, not conversation details
- Group by project
- Include specific file/feature names
- Output in Markdown (starting with h2)

### DiaryStorage

Manages diary file I/O.

| Method | Description |
|--------|-------------|
| `save(entry)` | Save diary to `YYYY/MM/{date}.md` |
| `loadAll()` | Load all diary files |
| `load(dateString)` | Load specific diary |
| `exists(dateString)` | Check if diary exists |

## Data Models

### HistoryEntry

```swift
struct HistoryEntry: Codable, Sendable {
    let display: String      // User input text
    let timestamp: Int       // Unix timestamp (ms)
    let project: String      // Full project path
}
```

### ConversationEntry

```swift
struct ConversationEntry: Codable, Sendable {
    let type: String         // "user", "assistant", "summary", etc.
    let message: Message?
    let timestamp: String    // ISO 8601
}

struct Message: Codable, Sendable {
    let role: String
    let content: ContentValue  // String or [ContentBlock]
}
```

### DayStatistics

Fast statistics without conversation content.

```swift
struct DayStatistics: Sendable {
    let date: Date
    let ccProjectCount: Int
    let ccSessionCount: Int
    let ccMessageCount: Int
    let cursorProjectCount: Int
    let cursorSessionCount: Int
    let cursorMessageCount: Int
    let codexProjectCount: Int
    let codexSessionCount: Int
    let codexMessageCount: Int
    let projects: [ProjectSummary]
}

struct ProjectSummary: Sendable {
    let name: String
    let path: String
    let messageCount: Int
    let timeRange: ClosedRange<Date>

    var formattedDuration: String  // "2h 15m"
}
```

### DailyActivity

Full activity data with conversation content.

```swift
struct DailyActivity: Sendable {
    let date: Date
    var projects: [ProjectActivity]
    var totalInputs: Int
}

struct ProjectActivity: Sendable {
    let path: String
    let name: String
    var userInputs: [String]
    var conversations: [ConversationMessage]
    var timeRange: ClosedRange<Date>
    var stats: ProjectStats
}

struct ProjectStats: Sendable {
    var totalMessages: Int
    var usedMessages: Int
    var totalChars: Int
    var usedChars: Int
    var truncatedCount: Int
}
```

### DiaryEntry

```swift
struct DiaryEntry: Codable, Sendable {
    let dateString: String   // YYYY-MM-DD
    let markdown: String
    let generatedAt: Date
}
```

## File Structure

```text
CCDiary/
├── Package.swift
├── project.yml              # XcodeGen config
├── scripts/                 # Build scripts
├── docs/
│   └── ARCHITECTURE.md
└── Sources/CCDiary/
    ├── CCDiaryApp.swift           # App entry point
    ├── Models/
    │   ├── ActivitySource.swift
    │   ├── AIProvider.swift
    │   ├── ConversationEntry.swift
    │   ├── CursorHistoryEntry.swift
    │   ├── DayStatistics.swift
    │   ├── DiaryContent.swift
    │   ├── DiaryEntry.swift
    │   ├── HistoryEntry.swift
    │   └── ProjectActivity.swift
    ├── Services/
    │   ├── AggregatorService.swift
    │   ├── ClaudeAPIService.swift
    │   ├── ConversationService.swift
    │   ├── CodexService.swift
    │   ├── CursorService.swift
    │   ├── DateFormatting.swift
    │   ├── DiaryFormatter.swift
    │   ├── DiaryGenerator.swift
    │   ├── DiaryPromptBuilder.swift
    │   ├── DiaryStorage.swift
    │   ├── GeminiAPIService.swift
    │   ├── HistoryService.swift
    │   ├── KeychainHelper.swift
    │   ├── ParseResult.swift
    │   └── StatisticsCache.swift
    └── Views/
        ├── CalendarGridView.swift
        ├── ContentView.swift
        ├── MarkdownWebView.swift
        ├── RightPaneView.swift
        └── SettingsView.swift
```

## Data Sources

### Claude Code

#### ~/.claude/history.jsonl

Global log of all user inputs across all projects.

```json
{
  "display": "fix the bug in auth",
  "pastedContents": {},
  "timestamp": 1737449123456,
  "project": "/path/to/myproject"
}
```

#### ~/.claude/projects/{encoded-path}/*.jsonl

Detailed conversation files per project.

Path encoding: `/path/to/myproject` → `-path-to-myproject`

```json
{
  "type": "user",
  "message": {
    "role": "user",
    "content": "fix the auth bug"
  },
  "timestamp": "2026-01-20T10:30:00.000Z"
}
```

### Cursor

#### ~/Library/Application Support/Cursor/User/globalStorage/state.vscdb

SQLite database containing chat history.

- `cursorDiskKV` table: Chat messages (key: `bubbleId:{composerId}:{messageId}`)
- `ItemTable` table: Composer session data and daily stats

#### ~/Library/Application Support/Cursor/User/workspaceStorage/{hash}/state.vscdb

Per-workspace SQLite database containing composer session metadata.

### Codex CLI / App

#### ~/.codex/sessions/**/*.jsonl

Current event-based session format (session metadata + response items).

#### ~/.codex/sessions/**/*.json

Legacy session format with `session` + `items[]`.

## Token Optimization

To manage API costs:

- Max 10000 chars per message (truncated)
- Limit messages per project (first half + last half)
- Quick statistics mode for browsing (no content loaded)

## Dependencies

- **[marked](https://github.com/markedjs/marked)** (v15.0.12) - Markdown parser (bundled)
- **[github-markdown-css](https://github.com/sindresorhus/github-markdown-css)** - GitHub Markdown styles (bundled)

## Error Handling

| Scenario | Handling |
|----------|----------|
| Missing history.jsonl | Show error message |
| Malformed JSON lines | Silently skipped |
| Missing conversation files | Skipped |
| No activity for date | Show "No activity" message |
| API auth error | Show error, prompt for API key |
| Network error | Show error message |
