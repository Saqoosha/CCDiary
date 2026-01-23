import Foundation

/// Service for generating diary using Claude Code CLI
actor ClaudeCLIService {
    /// JSON schema for structured diary output
    private let jsonSchema = """
    {
      "type": "object",
      "properties": {
        "summary": {
          "type": "string",
          "description": "1日の作業をまとめた2-3文の概要"
        },
        "projects": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "name": {"type": "string", "description": "プロジェクト名"},
              "tasks": {
                "type": "array",
                "items": {"type": "string"},
                "description": "作業内容のリスト"
              }
            },
            "required": ["name", "tasks"]
          }
        },
        "highlights": {
          "type": "array",
          "items": {"type": "string"},
          "description": "本日のハイライト"
        }
      },
      "required": ["summary", "projects", "highlights"]
    }
    """

    /// Generate diary from activity data using Claude Code CLI
    func generateDiary(activity: DailyActivity, model: String = "sonnet") async throws -> DiaryContent {
        let userPrompt = DiaryPromptBuilder.buildPromptWithInstruction(activity: activity)

        // Find claude CLI
        let claudePath = try await findClaudeCLI()

        // Run CLI process asynchronously
        let (outputData, errorData, exitCode) = try await runCLIProcess(
            claudePath: claudePath,
            prompt: userPrompt,
            model: model
        )

        guard exitCode == 0 else {
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw ClaudeCLIError.executionFailed(exitCode: exitCode, message: errorMessage)
        }

        // Parse CLI response
        guard let response = try? JSONDecoder().decode(CLIResponse.self, from: outputData) else {
            let rawOutput = String(data: outputData, encoding: .utf8) ?? ""
            throw ClaudeCLIError.invalidResponse(rawOutput)
        }

        guard let structuredOutput = response.structured_output else {
            throw ClaudeCLIError.noStructuredOutput
        }

        // Generate markdown body from structured output (without header/footer)
        let rawMarkdown = generateMarkdownBody(from: structuredOutput)

        return DiaryContent(
            date: activity.date,
            rawMarkdown: rawMarkdown
        )
    }

    /// Run CLI process asynchronously
    private func runCLIProcess(
        claudePath: String,
        prompt: String,
        model: String
    ) async throws -> (output: Data, error: Data, exitCode: Int32) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: claudePath)
            process.arguments = [
                "-p",
                "--output-format", "json",
                "--json-schema", jsonSchema,
                "--system-prompt", DiaryPromptBuilder.structuredSystemPrompt,
                "--model", model
            ]

            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            process.terminationHandler = { proc in
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (outputData, errorData, proc.terminationStatus))
            }

            do {
                try process.run()

                // Write prompt to stdin and close
                if let promptData = prompt.data(using: .utf8) {
                    inputPipe.fileHandleForWriting.write(promptData)
                }
                inputPipe.fileHandleForWriting.closeFile()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Find Claude CLI executable
    private func findClaudeCLI() async throws -> String {
        // Check common locations
        let possiblePaths = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude"
        ]

        for path in possiblePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Try using 'which' command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["claude"]

        let pipe = Pipe()
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        }

        throw ClaudeCLIError.cliNotFound
    }



    /// Generate markdown body from structured diary output (without header/footer)
    private func generateMarkdownBody(from diary: DiaryOutput) -> String {
        var markdown = ""

        // Summary
        markdown += "## 概要\n\n"
        markdown += "\(diary.summary)\n\n"

        // Projects
        markdown += "## 作業内容\n\n"
        for project in diary.projects {
            markdown += "### \(project.name)\n\n"
            for task in project.tasks {
                markdown += "- \(task)\n"
            }
            markdown += "\n"
        }

        // Highlights
        if !diary.highlights.isEmpty {
            markdown += "## 本日のハイライト\n\n"
            for highlight in diary.highlights {
                markdown += "- \(highlight)\n"
            }
        }

        return markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Response Types

/// CLI JSON response structure
private struct CLIResponse: Decodable {
    let type: String
    let subtype: String?
    let is_error: Bool
    let result: String?
    let structured_output: DiaryOutput?
}

/// Structured diary output
struct DiaryOutput: Decodable {
    let summary: String
    let projects: [ProjectOutput]
    let highlights: [String]
}

/// Project output in diary
struct ProjectOutput: Decodable {
    let name: String
    let tasks: [String]
}

// MARK: - Errors

enum ClaudeCLIError: LocalizedError {
    case cliNotFound
    case executionFailed(exitCode: Int32, message: String)
    case invalidResponse(String)
    case noStructuredOutput

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "Claude Code CLI not found. Please install it first."
        case .executionFailed(let exitCode, let message):
            return "CLI execution failed (exit code \(exitCode)): \(message)"
        case .invalidResponse(let raw):
            return "Invalid CLI response: \(raw.prefix(200))"
        case .noStructuredOutput:
            return "No structured output in CLI response"
        }
    }
}
