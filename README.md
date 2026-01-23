# ccdiary

A macOS app that automatically generates work diaries in Japanese from Claude Code conversation history.

## Features

- Automatically collects Claude Code conversation history
- Calendar-centric UI (dynamically shows from earliest activity to end of current month)
- Organizes activities by project
- Multiple AI provider support (Claude CLI / Claude API / Gemini API)
- Handles large files efficiently (87MB+ log files with binary search optimization)
- Saves and displays diaries in Markdown format

## Data Sources

Reads the following files recorded by Claude Code:

- `~/.claude/history.jsonl` - Input history across all projects
- `~/.claude/projects/{encoded-path}/*.jsonl` - Detailed conversation logs per project

## Requirements

- macOS 14.0+
- Xcode 15+ (for building)
- One of the following:
  - Claude Code CLI (no additional setup required if already installed)
  - Anthropic API Key
  - Google Gemini API Key

## Build

```bash
# Debug build
swift build

# Release build
swift build -c release

# Generate Xcode project from project.yml
xcodegen generate

# Build with xcodebuild
xcodebuild -scheme ccdiary -configuration Debug -derivedDataPath build build

# Run
open build/Build/Products/Debug/ccdiary.app
```

Or open directly in Xcode:

```bash
open Package.swift
```

## App Features

### Calendar View

- Continuous scrollable calendar from earliest activity to end of current month
- Days with activity are marked with a dot
- Days with generated diaries show a checkmark
- Auto-scrolls to today on launch

### Day View

- Statistics for selected day (projects, sessions, messages, characters)
- Activity breakdown by project
- Displays generated diary
- Copy button to clipboard

### Diary Generation

- Generate diary with the Generate button
- Uses Claude Sonnet API
- Shows progress indicator

### Settings

- **AI Provider**: Choose your preferred AI provider
  - Claude CLI (no API key required if Claude Code is installed)
  - Claude API (requires Anthropic API key)
  - Gemini API (requires Google AI API key)
- **Model**: Model to use (for Claude CLI: sonnet/opus/haiku)
- **Diaries Directory**: Where to save diaries (default: `~/Desktop/ccdiary/diaries`)

## Output

Diaries are saved in Markdown format:

```
diaries/
├── 2026-01-20.md
├── 2026-01-21.md
└── 2026-01-22.md
```

### Sample Output

```markdown
## Summary

Today I worked on 3 projects, mainly focusing on API improvements and bug fixes.

## By Project

### my-project

- Fixed authentication bug
- Added pagination to user list API
- Improved test coverage

### another-project

- Created new component
- Adjusted styling

## Today's Highlight

Resolved authentication issues and prepared for a stable release.
```

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for detailed architecture documentation.

## License

MIT
