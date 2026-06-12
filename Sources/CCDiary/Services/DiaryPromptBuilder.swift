import Foundation

/// Shared prompt building logic for all AI diary generators
enum DiaryPromptBuilder {
    /// System prompt for diary generation
    static let systemPrompt = """
    Claude Code / Cursor / Codex の開発チャット履歴から作業日記を日本語で作成してください。

    ルール:
    - 入力の「プロジェクト一覧」の全ての名前について、その名前を見出しに含む ### セクションを必ず作る。どの名前も省略禁止
    - 同じ名前の入力が複数ある場合（別ツール・別 Mac・「[from ホスト名]」タグ付きを含む）は1つのセクションにまとめる。同一見出しを2回作らない。「[from ...]」タグは見出しに含めない
    - 実質的に同じプロジェクトを1つのセクションにまとめる場合は、一覧にある該当する全ての名前を見出しに含める（例: ### Loadmap（旧 Resourcer））
    - 各プロジェクトで「何をやったか」を2-4個の箇条書きで書く
    - 1つの箇条書きは1行で簡潔に
    - h1は使わない、h2から開始

    出力形式:
    ## 概要
    （1-2文で今日の作業を要約）

    ## 作業内容
    ### プロジェクト名
    - やったこと1
    - やったこと2
    """

    /// System prompt for structured output (JSON)
    static let structuredSystemPrompt = """
    あなたは技術日記アシスタントです。Claude Code / Cursor / Codex の開発チャット履歴を分析して、作業日記を生成してください。

    ガイドライン:
    - 会話の詳細ではなく、何を達成したかに焦点を当てる
    - プロジェクトごとに作業内容をまとめる
    - 各タスクは1行で簡潔に書く（ネストしたリストや改行は使わない）
    - 1プロジェクトあたり2-5個のタスクに絞る
    - 具体的なファイル名や機能名があれば含める

    出力は指定されたJSONスキーマに従ってください。
    """

    /// Canonical section name for a project: the host-stats merge step tags
    /// remote-only projects ("B [from host]"), but diary sections should use
    /// the plain project name. Only the tag is stripped — legitimate project
    /// names (even ones containing " + ") pass through untouched.
    static func sectionName(for projectName: String) -> String {
        var name = projectName
        if let from = name.range(of: " [from ") {
            name = String(name[..<from.lowerBound])
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? projectName : trimmed
    }

    /// Unique section names for all projects, in activity order.
    static func requiredSectionNames(activity: DailyActivity) -> [String] {
        var seen = Set<String>()
        return activity.projects
            .map { sectionName(for: $0.name) }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    /// Project sections the generated markdown failed to include. A project
    /// counts as covered when any `###` heading contains its section name
    /// (case-insensitive) — so "### Loadmap (旧Resourcer)" covers both
    /// "Loadmap" and "Resourcer".
    static func missingProjectSections(in markdown: String, activity: DailyActivity) -> [String] {
        let headings = sectionHeadings(in: markdown)
        return requiredSectionNames(activity: activity).filter { name in
            let needle = name.lowercased()
            return !headings.contains { $0.contains(needle) }
        }
    }

    /// Headings that appear more than once — the model occasionally writes
    /// two sections for a project that has entries from multiple tools or
    /// hosts instead of merging them as instructed.
    static func duplicatedSections(in markdown: String) -> [String] {
        var counts: [String: Int] = [:]
        for heading in sectionHeadings(in: markdown) {
            counts[heading, default: 0] += 1
        }
        return counts.filter { $0.value > 1 }.map(\.key).sorted()
    }

    private static func sectionHeadings(in markdown: String) -> [String] {
        markdown
            .split(separator: "\n")
            .filter { $0.hasPrefix("### ") }
            .map { $0.dropFirst(4).trimmingCharacters(in: .whitespaces).lowercased() }
    }

    /// Build user prompt from activity data
    static func buildPrompt(activity: DailyActivity) -> String {
        var prompt = "## 日付: \(activity.formattedDate)\n\n"
        prompt += "## 本日の作業プロジェクト数: \(activity.projects.count)\n"
        prompt += "## 総入力数: \(activity.totalInputs)\n\n"

        let sectionNames = requiredSectionNames(activity: activity)
        prompt += "## プロジェクト一覧（全\(sectionNames.count)件 — それぞれに必ず ### セクションを作成）:\n"
        for name in sectionNames {
            prompt += "- \(name)\n"
        }
        prompt += "\n"

        for project in activity.projects {
            prompt += "### \(project.name)\n"
            prompt += "パス: \(project.path)\n"
            prompt += "作業時間: \(project.formattedTimeRange)\n"
            prompt += "メッセージ数: \(project.stats.usedMessages)/\(project.stats.totalMessages)\n\n"

            if !project.conversations.isEmpty {
                prompt += "#### 会話:\n"
                for msg in project.conversations {
                    let role = msg.role == .user ? "👤" : "🤖"
                    prompt += "\(role): \(msg.content)\n"
                }
                prompt += "\n"
            } else if !project.userInputs.isEmpty {
                prompt += "#### ユーザー入力:\n"
                for input in project.userInputs {
                    prompt += "- \(input)\n"
                }
                prompt += "\n"
            }

            prompt += "---\n\n"
        }

        return prompt
    }

    /// Build prompt with instruction prefix
    static func buildPromptWithInstruction(activity: DailyActivity) -> String {
        "以下のClaude Code / Cursor / Codex の開発チャット履歴から作業日記を生成してください。\n\n\(buildPrompt(activity: activity))"
    }
}
