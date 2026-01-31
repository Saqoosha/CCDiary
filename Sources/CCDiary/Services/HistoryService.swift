import Foundation
import os.log

private let logger = Logger(subsystem: "CCDiary", category: "HistoryService")

/// Service for reading Claude Code history
actor HistoryService {
    private let historyPath: URL
    private var cachedEntries: [HistoryEntry]?
    private var cachedModTime: Date?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.historyPath = home.appendingPathComponent(".claude/history.jsonl")
    }

    /// Read all history entries (cached)
    func readHistory() async throws -> [HistoryEntry] {
        // Check if file has been modified since last read
        let attrs = try FileManager.default.attributesOfItem(atPath: historyPath.path)
        let modTime = attrs[.modificationDate] as? Date

        if let cached = cachedEntries,
           let cachedMod = cachedModTime,
           let currentMod = modTime,
           cachedMod == currentMod {
            return cached
        }

        let result = try await readHistoryWithResult()
        cachedEntries = result.entries
        cachedModTime = modTime
        return result.entries
    }

    /// Read history entries with parse result tracking
    func readHistoryWithResult() async throws -> ParseResult<HistoryEntry> {
        let startTime = CFAbsoluteTimeGetCurrent()

        guard FileManager.default.fileExists(atPath: historyPath.path) else {
            throw HistoryError.fileNotFound(historyPath.path)
        }

        let data = try Data(contentsOf: historyPath)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HistoryError.invalidEncoding
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let decoder = JSONDecoder()

        var entries: [HistoryEntry] = []
        var errors: [String] = []
        var skippedCount = 0

        for (index, line) in lines.enumerated() {
            guard let lineData = line.data(using: .utf8) else {
                skippedCount += 1
                continue
            }
            do {
                let entry = try decoder.decode(HistoryEntry.self, from: lineData)
                entries.append(entry)
            } catch {
                skippedCount += 1
                let errorMsg = "Line \(index + 1): \(error.localizedDescription)"
                errors.append(errorMsg)
                if errors.count <= 3 {
                    logger.debug("Parse error in history.jsonl: \(errorMsg)")
                }
            }
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logger.info("readHistory: \(elapsed, format: .fixed(precision: 1))ms (\(entries.count) entries)")

        return ParseResult(entries: entries, skippedCount: skippedCount, errors: errors)
    }

    /// Filter entries by date
    nonisolated func filterByDate(_ entries: [HistoryEntry], date: Date) -> [HistoryEntry] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return []
        }

        let startMs = Int64(startOfDay.timeIntervalSince1970 * 1000)
        let endMs = Int64(endOfDay.timeIntervalSince1970 * 1000)

        return entries.filter { entry in
            entry.timestamp >= startMs && entry.timestamp < endMs
        }
    }

    /// Group entries by project path
    nonisolated func groupByProject(_ entries: [HistoryEntry]) -> [String: [HistoryEntry]] {
        var groups: [String: [HistoryEntry]] = [:]

        for entry in entries {
            groups[entry.project, default: []].append(entry)
        }

        return groups
    }

    /// Extract project name from path
    static func getProjectName(_ projectPath: String) -> String {
        (projectPath as NSString).lastPathComponent
    }
}

enum HistoryError: LocalizedError {
    case fileNotFound(String)
    case invalidEncoding

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "History file not found: \(path)"
        case .invalidEncoding:
            return "Invalid file encoding"
        }
    }
}
