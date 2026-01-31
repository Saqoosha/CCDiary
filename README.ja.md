[English](README.md) | 日本語

# CCDiary

<p align="center">
  <img src="images/appicon.png" width="128" height="128" alt="CCDiary icon">
  <br>
  Claude CodeとCursorのチャット履歴から作業日記を自動生成するmacOSアプリ
</p>

![CCDiary screenshot](images/screenshot-v2.png)

## 特徴

- **自動履歴収集** - Claude CodeとCursorのチャット履歴を自動で収集
- **カレンダー中心のUI** - 最初のアクティビティから今月末までを動的に表示
- **プロジェクト別整理** - アクティビティをプロジェクトごとに整理
- **複数プロバイダー対応** - Claude API / Gemini APIから選択可能
- **大規模ファイル対応** - 87MB超のログファイルもバイナリサーチで高速処理
- **Markdown出力** - 日記をMarkdown形式で保存・表示

## インストール

1. [Releases](https://github.com/Saqoosha/CCDiary/releases)から最新の`.dmg`をダウンロード
2. DMGを開き、`CCDiary.app`をアプリケーションフォルダにドラッグ
3. アプリを起動

## 設定

### AIプロバイダー

1. CCDiary.appを開く
2. 設定（歯車アイコン）を開く
3. AIプロバイダーを選択:
   - **Claude API** - Anthropic APIキーが必要
   - **Gemini API** - Google AI APIキーが必要
4. APIキーを入力
5. 「保存」をクリック

### 日記の保存先

デフォルトでは`~/Documents/CCDiary/`に保存されます。設定から変更できます。

## 使い方

### カレンダービュー

- 最初のアクティビティから今月末までスクロール可能なカレンダー
- アクティビティがある日はドットで表示
- 日記が生成済みの日はチェックマークを表示
- 起動時に今日の日付まで自動スクロール

### 日別ビュー

- 選択した日の統計（プロジェクト数、セッション数、メッセージ数）
- プロジェクト別のアクティビティ内訳
- 生成された日記を表示
- クリップボードにコピーするボタン

### 日記生成

1. アクティビティがある日を選択
2. 「生成」ボタンをクリック
3. AIが日記を生成するのを待つ
4. 日記は自動的に保存される

## データソース

### Claude Code

- `~/.claude/history.jsonl` - 全プロジェクトの入力履歴
- `~/.claude/projects/{encoded-path}/*.jsonl` - プロジェクトごとの詳細な会話ログ

### Cursor

- `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` - チャット履歴データベース

## 出力

日記はMarkdown形式で保存されます:

```
~/Documents/CCDiary/
├── 2026-01-20.md
├── 2026-01-21.md
└── 2026-01-22.md
```

### 出力サンプル

```markdown
## 概要

今日は3つのプロジェクトで作業し、主にAPI改善とバグ修正に取り組みました。

## プロジェクト別

### my-project

- 認証バグを修正
- ユーザー一覧APIにページネーションを追加
- テストカバレッジを改善

### another-project

- 新しいコンポーネントを作成
- スタイリングを調整

## 今日のハイライト

認証の問題を解決し、安定したリリースに向けて準備が整いました。
```

---

## 開発

### 必要環境

- macOS 14.0以上
- Xcode 15以上
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

### ソースからビルド

```bash
git clone https://github.com/Saqoosha/CCDiary.git
cd CCDiary

# Xcodeプロジェクトを生成
xcodegen generate

# ビルド
xcodebuild -scheme CCDiary -configuration Debug -derivedDataPath build build

# 実行
open build/Build/Products/Debug/CCDiary.app
```

またはXcodeで直接開く:

```bash
open Package.swift
```

### アーキテクチャ

詳細なアーキテクチャドキュメントは[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)を参照してください。

## サードパーティライセンス

このプロジェクトは以下のオープンソースライブラリを使用しています:

- **[marked](https://github.com/markedjs/marked)** - Markdownパーサーおよびコンパイラ。MIT License, Copyright (c) 2011-2025, Christopher Jeffrey.
- **[github-markdown-css](https://github.com/sindresorhus/github-markdown-css)** - GitHubのMarkdownスタイル。MIT License, Copyright (c) Sindre Sorhus.

## ライセンス

MIT
