import Foundation

enum CCDiaryCLI {
    static func main() async {
        do {
            let options = try CLIOptions.parse(Array(CommandLine.arguments.dropFirst()))
            try await run(options)
        } catch CLIError.helpRequested {
            print(CLIOptions.help)
        } catch let error as CLIError {
            // Argument errors: show help to guide the caller.
            fputs("Error: \(error.localizedDescription)\n\n\(CLIOptions.help)\n", stderr)
            Foundation.exit(1)
        } catch {
            // Runtime errors (network, Slack API, etc.): help text would be noise in launchd logs.
            fputs("Error: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func run(_ options: CLIOptions) async throws {
        let aggregator = AggregatorService()
        let aggregateOptions = AggregateOptions(
            maxContentLength: options.maxContentLength,
            maxMessagesPerProject: options.maxMessagesPerProject
        )

        if options.buildIndex {
            print("Building indexes...")
            await aggregator.buildDateIndex()
        }

        print("Aggregating \(DateFormatting.iso.string(from: options.date))...")
        let activity = try await aggregator.aggregateForDate(options.date, options: aggregateOptions)

        if activity.projects.isEmpty {
            print("No activity found for \(activity.isoDateString).")
            return
        }

        if options.dryRun {
            printSummary(activity)
            return
        }

        let storage = options.outputDirectory.map { DiaryStorage(directory: $0) } ?? DiaryStorage()
        if await storage.exists(dateString: activity.isoDateString), !options.force {
            if options.skipExisting {
                let slackNote = options.postSlack ? " (Slack post also skipped)" : ""
                print("Diary already exists for \(activity.isoDateString). Skipping.\(slackNote)")
                return
            }
            throw CLIError.diaryAlreadyExists(activity.isoDateString)
        }

        let content = try await generateDiary(activity: activity, options: options)
        let entry = DiaryFormatter.format(content)
        try await storage.save(entry)
        let directoryPath = await storage.directoryPath
        print("Saved \(directoryPath)/\(entry.dateString).md")

        if options.postSlack {
            let result = try await postToSlack(entry: entry, options: options)
            print("Posted to Slack channel \(result.channel) at \(result.timestamp)")
            if result.truncated {
                fputs("Warning: diary exceeded Slack's block limits and was truncated.\n", stderr)
            }
        }
    }

    private static func generateDiary(activity: DailyActivity, options: CLIOptions) async throws -> DiaryContent {
        let provider = options.provider
        let apiKey = resolveAPIKey(for: provider)
        guard let apiKey else {
            throw AIAPIError.missingAPIKey(provider: provider)
        }

        let service: any AIAPIService
        let defaultModel: String
        switch provider {
        case .claudeAPI:
            service = ClaudeAPIService()
            defaultModel = "claude-haiku-4-5-20251101"
        case .gemini:
            service = GeminiAPIService()
            defaultModel = "gemini-2.5-flash"
        case .openai:
            service = OpenAIAPIService()
            defaultModel = "gpt-5-mini"
        }

        return try await service.generateDiary(
            activity: activity,
            apiKey: apiKey,
            model: options.model ?? defaultModel
        )
    }

    private static func resolveAPIKey(for provider: AIProvider) -> String? {
        let envKey: String
        switch provider {
        case .claudeAPI: envKey = "ANTHROPIC_API_KEY"
        case .gemini:    envKey = "GEMINI_API_KEY"
        case .openai:    envKey = "OPENAI_API_KEY"
        }
        return ProcessInfo.processInfo.environment[envKey]
            ?? KeychainHelper.load(service: provider.keychainService)
    }

    private static func postToSlack(entry: DiaryEntry, options: CLIOptions) async throws -> SlackPostResult {
        let botToken = ProcessInfo.processInfo.environment["SLACK_BOT_TOKEN"]
            ?? KeychainHelper.load(service: KeychainHelper.slackBotTokenService)
        guard let botToken else {
            throw SlackServiceError.missingBotToken
        }
        guard botToken.hasPrefix("xoxb-") else {
            throw SlackServiceError.invalidBotTokenFormat(prefix: String(botToken.prefix(5)))
        }

        guard let channel = configuredSlackChannel(options: options) else {
            throw SlackServiceError.missingChannel
        }

        let service = SlackService()
        return try await service.postDiary(entry, channel: channel, botToken: botToken)
    }

    private static func configuredSlackChannel(options: CLIOptions) -> String? {
        [
            options.slackChannel,
            ProcessInfo.processInfo.environment["CCDIARY_SLACK_CHANNEL"],
            ProcessInfo.processInfo.environment["SLACK_CHANNEL_ID"],
            CLIOptions.defaultSlackChannel
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
    }

    private static func printSummary(_ activity: DailyActivity) {
        print("Dry run for \(activity.isoDateString)")
        print("Projects: \(activity.projects.count)")
        print("User inputs: \(activity.totalInputs)")

        let grouped = Dictionary(grouping: activity.projects, by: \.source)
        for source in ActivitySource.allCases where source != .all {
            guard let projects = grouped[source], !projects.isEmpty else { continue }
            let messages = projects.reduce(0) { $0 + $1.stats.totalMessages }
            print("- \(source.rawValue): \(projects.count) projects, \(messages) messages")
        }

        for project in activity.projects {
            let messageSummary: String
            if project.stats.usedMessages == project.stats.totalMessages {
                messageSummary = "\(project.stats.totalMessages) messages"
            } else {
                messageSummary = "\(project.stats.usedMessages)/\(project.stats.totalMessages) messages used"
            }
            print("  - [\(project.source.rawValue)] \(project.name): \(messageSummary), \(project.formattedTimeRange)")
        }
    }
}

private struct CLIOptions {
    var date: Date
    var dryRun: Bool
    var force: Bool
    var skipExisting: Bool
    var provider: AIProvider
    var model: String?
    var outputDirectory: URL?
    var maxContentLength: Int
    var maxMessagesPerProject: Int
    var buildIndex: Bool
    var postSlack: Bool
    var slackChannel: String?

    static let defaultSlackChannel = "C033F6U7147"

    static let help = """
    Usage:
      ccdiary-cli generate [--date YYYY-MM-DD | --yesterday | --today] [--dry-run] [--force | --skip-existing]
                           [--provider claude|gemini|openai] [--model MODEL] [--output-dir PATH]
                           [--max-content-length N] [--max-messages-per-project N] [--build-index]
                           [--post-slack] [--slack-channel CHANNEL_ID]

    Notes:
      --force and --skip-existing are mutually exclusive (rejected at parse time).
      --skip-existing also skips Slack posting when the diary already exists.
      Passing --slack-channel implies --post-slack.

    Environment:
      ANTHROPIC_API_KEY        Used for --provider claude before Keychain fallback
      GEMINI_API_KEY           Used for --provider gemini before Keychain fallback
      OPENAI_API_KEY           Used for --provider openai before Keychain fallback
      SLACK_BOT_TOKEN          Used for --post-slack before Keychain fallback
      CCDIARY_PROVIDER         Default provider (claude|gemini|openai)
      CCDIARY_SLACK_CHANNEL    Slack channel; takes precedence over SLACK_CHANNEL_ID
      SLACK_CHANNEL_ID         Slack channel; falls back to default (\(defaultSlackChannel))
                               --slack-channel beats both env vars and the default.
    """

    static func parse(_ arguments: [String]) throws -> CLIOptions {
        guard let command = arguments.first, command == "generate" else {
            throw CLIError.helpRequested
        }

        var date = Self.yesterday()
        var dryRun = false
        var force = false
        var skipExisting = false
        var provider = Self.defaultProvider()
        var model: String?
        var outputDirectory: URL?
        var maxContentLength = 10_000
        var maxMessagesPerProject = 1_000
        var buildIndex = false
        var postSlack = false
        var slackChannel: String?

        var index = 1
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--help", "-h":
                throw CLIError.helpRequested
            case "--today":
                date = Date()
            case "--yesterday":
                date = Self.yesterday()
            case "--dry-run":
                dryRun = true
            case "--force":
                force = true
            case "--skip-existing":
                skipExisting = true
            case "--build-index":
                buildIndex = true
            case "--post-slack":
                postSlack = true
            case "--date":
                index += 1
                guard index < arguments.count,
                      let parsedDate = DateFormatting.iso.date(from: arguments[index]) else {
                    throw CLIError.invalidArgument("--date requires YYYY-MM-DD")
                }
                date = parsedDate
            case "--provider":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArgument("--provider requires claude or gemini")
                }
                provider = try parseProvider(arguments[index])
            case "--model":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArgument("--model requires a value")
                }
                model = arguments[index]
            case "--output-dir":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArgument("--output-dir requires a path")
                }
                outputDirectory = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            case "--max-content-length":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                    throw CLIError.invalidArgument("--max-content-length requires a positive integer")
                }
                maxContentLength = value
            case "--max-messages-per-project":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                    throw CLIError.invalidArgument("--max-messages-per-project requires a positive integer")
                }
                maxMessagesPerProject = value
            case "--slack-channel":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty else {
                    throw CLIError.invalidArgument("--slack-channel requires a channel ID")
                }
                slackChannel = arguments[index]
                postSlack = true
            default:
                throw CLIError.invalidArgument("Unknown argument: \(arg)")
            }
            index += 1
        }

        if force && skipExisting {
            throw CLIError.invalidArgument("--force and --skip-existing are mutually exclusive")
        }

        return CLIOptions(
            date: date,
            dryRun: dryRun,
            force: force,
            skipExisting: skipExisting,
            provider: provider,
            model: model,
            outputDirectory: outputDirectory,
            maxContentLength: maxContentLength,
            maxMessagesPerProject: maxMessagesPerProject,
            buildIndex: buildIndex,
            postSlack: postSlack,
            slackChannel: slackChannel
        )
    }

    private static func parseProvider(_ value: String) throws -> AIProvider {
        switch value.lowercased() {
        case "claude", "claude-api", "anthropic":
            return .claudeAPI
        case "gemini", "google":
            return .gemini
        case "openai", "gpt":
            return .openai
        default:
            throw CLIError.invalidArgument("--provider requires claude, gemini, or openai")
        }
    }

    // The CLI and the GUI app live under different bundle IDs
    // (`sh.saqoo.ccdiary-cli` vs `sh.saqoo.CCDiary`), so `UserDefaults.standard`
    // can't see the GUI's `aiProvider`. Use `CCDIARY_PROVIDER` to override.
    private static func defaultProvider() -> AIProvider {
        if let envProvider = ProcessInfo.processInfo.environment["CCDIARY_PROVIDER"],
           let provider = try? parseProvider(envProvider) {
            return provider
        }
        return .claudeAPI
    }

    private static func yesterday() -> Date {
        Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    }
}

private enum CLIError: LocalizedError {
    case helpRequested
    case invalidArgument(String)
    case diaryAlreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .helpRequested:
            return nil
        case .invalidArgument(let message):
            return message
        case .diaryAlreadyExists(let dateString):
            return "Diary already exists for \(dateString). Pass --force to overwrite it."
        }
    }
}

await CCDiaryCLI.main()
