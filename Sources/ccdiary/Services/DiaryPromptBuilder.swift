import Foundation

/// Shared prompt building logic for all AI diary generators
enum DiaryPromptBuilder {
    /// System prompt for diary generation
    static let systemPrompt = """
    Claude Codeの会話履歴から作業日記を日本語で作成してください。

    ルール:
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
    あなたは技術日記アシスタントです。Claude Codeの会話履歴を分析して、作業日記を生成してください。

    ガイドライン:
    - 会話の詳細ではなく、何を達成したかに焦点を当てる
    - プロジェクトごとに作業内容をまとめる
    - 主要な成果と課題を特定する
    - 簡潔だが情報量のある内容にする
    - 具体的なファイル名や機能名があれば含める

    出力は指定されたJSONスキーマに従ってください。
    """

    /// Build user prompt from activity data
    static func buildPrompt(activity: DailyActivity) -> String {
        var prompt = "## 日付: \(activity.formattedDate)\n\n"
        prompt += "## 本日の作業プロジェクト数: \(activity.projects.count)\n"
        prompt += "## 総入力数: \(activity.totalInputs)\n\n"

        for project in activity.projects {
            prompt += "### プロジェクト: \(project.name)\n"
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
        "以下のClaude Code会話履歴から作業日記を生成してください。\n\n\(buildPrompt(activity: activity))"
    }
}
