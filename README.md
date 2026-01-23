# ccdiary

Claude Code の会話履歴から自動で日本語の作業日記を生成する macOS アプリ。

## Features

- Claude Code の会話履歴を自動収集
- カレンダー中心の UI（180日前〜90日後）
- プロジェクト別に活動を整理
- 複数の AI プロバイダー対応（Claude CLI / Claude API / Gemini API）
- 大容量ファイル対応（87MB+ のログファイルも高速処理）
- Markdown 形式で保存・表示

## Data Sources

Claude Code が記録する以下のファイルを読み取る:

- `~/.claude/history.jsonl` - 全プロジェクトの入力履歴
- `~/.claude/projects/{encoded-path}/*.jsonl` - プロジェクト別の詳細な会話ログ

## Requirements

- macOS 14.0+
- Xcode 15+ (ビルド用)
- いずれかの API キー:
  - Claude Code CLI（インストール済みであれば追加設定不要）
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

または Xcode で直接開く:

```bash
open Package.swift
```

## App Features

### Calendar View

- 180日前から90日後までの連続カレンダー
- 活動がある日にはドットが表示される
- 日記が生成済みの日はチェックマークが表示される
- 今日にスクロール

### Day View

- 選択した日の統計（プロジェクト数、セッション数、メッセージ数、文字数）
- プロジェクト別のアクティビティ
- 生成済みの日記を表示
- Copy ボタンでクリップボードにコピー

### Diary Generation

- Generate ボタンで日記を生成
- Claude Sonnet API を使用
- 進捗インジケータ付き

### Settings

- **AI Provider**: 使用する AI プロバイダー
  - Claude CLI（API キー不要、Claude Code がインストールされていれば使用可能）
  - Claude API（Anthropic API キーが必要）
  - Gemini API（Google AI API キーが必要）
- **Model**: 使用するモデル（Claude CLI の場合: sonnet/opus/haiku）
- **Diaries Directory**: 日記の保存先（デフォルト: `~/Desktop/ccdiary/diaries`）

## Output

日記は Markdown 形式で保存される:

```
diaries/
├── 2026-01-20.md
├── 2026-01-21.md
└── 2026-01-22.md
```

### Sample Output

```markdown
## 概要

本日は3つのプロジェクトで作業を行い、主にAPIの改善とバグ修正に取り組んだ。

## プロジェクト別

### my-project

- 認証機能のバグを修正
- ユーザー一覧APIにページネーションを追加
- テストカバレッジを向上

### another-project

- 新しいコンポーネントを作成
- スタイリングの調整

## 本日のハイライト

認証周りの問題を解決し、安定したリリースの準備が整った。
```

## Architecture

詳細なアーキテクチャについては [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) を参照。

## License

MIT
