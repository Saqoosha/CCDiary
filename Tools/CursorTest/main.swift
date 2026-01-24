import Foundation
import SQLite3

// MARK: - Hex Decoding

extension Data {
    init?(hexString: String) {
        let hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count % 2 == 0 else { return nil }

        var data = Data(capacity: hex.count / 2)

        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }
}

// MARK: - Test Functions

func testCursorDB(dateString: String?) {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let globalDBPath = "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    let workspaceStoragePath = "\(home)/Library/Application Support/Cursor/User/workspaceStorage"

    print("=== Cursor DB Test ===")
    print("Global DB: \(globalDBPath)")
    print()

    guard FileManager.default.fileExists(atPath: globalDBPath) else {
        print("ERROR: Cursor database not found!")
        return
    }

    // Show daily stats
    print("=== Daily Stats (from ItemTable) ===")
    showDailyStats(dbPath: globalDBPath)

    // Test workspace-based messages
    if let dateString = dateString {
        print("\n=== Workspace-Based Messages for \(dateString) ===")
        testWorkspaceMessages(globalDBPath: globalDBPath, workspaceStoragePath: workspaceStoragePath, dateString: dateString)
    } else {
        print("\nUsage: cursor-test [YYYY-MM-DD]")
        print("Pass a date to see messages for that day")
    }
}

func showDailyStats(dbPath: String) {
    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
    guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK else {
        print("ERROR: Failed to open database")
        return
    }
    defer { sqlite3_close(db) }

    let query = "SELECT key, value FROM ItemTable WHERE key LIKE 'aiCodeTracking.dailyStats%' ORDER BY key DESC LIMIT 10"
    var stmt: OpaquePointer?

    if sqlite3_prepare_v2(db, query, -1, &stmt, nil) != SQLITE_OK {
        print("ERROR: \(String(cString: sqlite3_errmsg(db)))")
        return
    }
    defer { sqlite3_finalize(stmt) }

    while sqlite3_step(stmt) == SQLITE_ROW {
        guard let keyPtr = sqlite3_column_text(stmt, 0) else { continue }
        let key = String(cString: keyPtr)

        // Extract date from key
        let dateStr = key.split(separator: ".").last ?? "unknown"

        if let valuePtr = sqlite3_column_blob(stmt, 1) {
            let valueLength = sqlite3_column_bytes(stmt, 1)
            if valueLength > 0 {
                let valueData = Data(bytes: valuePtr, count: Int(valueLength))
                if let json = try? JSONSerialization.jsonObject(with: valueData) as? [String: Any] {
                    let tabSuggested = json["tabSuggestedLines"] as? Int ?? 0
                    let tabAccepted = json["tabAcceptedLines"] as? Int ?? 0
                    let composerSuggested = json["composerSuggestedLines"] as? Int ?? 0
                    let composerAccepted = json["composerAcceptedLines"] as? Int ?? 0
                    print("  \(dateStr): Tab=\(tabAccepted)/\(tabSuggested), Composer=\(composerAccepted)/\(composerSuggested)")
                }
            }
        }
    }
}

func testWorkspaceMessages(globalDBPath: String, workspaceStoragePath: String, dateString: String) {
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"
    dateFormatter.timeZone = TimeZone.current

    guard let date = dateFormatter.date(from: dateString) else {
        print("ERROR: Invalid date format. Use YYYY-MM-DD")
        return
    }

    let calendar = Calendar.current
    let startOfDay = calendar.startOfDay(for: date)
    guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
        print("ERROR: Failed to calculate end of day")
        return
    }

    let startTs = startOfDay.timeIntervalSince1970 * 1000
    let endTs = endOfDay.timeIntervalSince1970 * 1000

    print("Date range: \(startOfDay) - \(endOfDay)")
    print()

    // Get all workspaces
    guard let workspaces = try? FileManager.default.contentsOfDirectory(atPath: workspaceStoragePath) else {
        print("ERROR: Cannot read workspace storage")
        return
    }

    var totalMessages = 0
    var projectsWithActivity: [(name: String, messages: Int, composers: [String])] = []

    for hash in workspaces {
        let workspaceDir = "\(workspaceStoragePath)/\(hash)"
        let workspaceJsonPath = "\(workspaceDir)/workspace.json"
        let stateDBPath = "\(workspaceDir)/state.vscdb"

        guard FileManager.default.fileExists(atPath: stateDBPath) else { continue }

        // Read workspace.json
        guard let jsonData = FileManager.default.contents(atPath: workspaceJsonPath),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let folderURL = json["folder"] as? String else {
            continue
        }

        let projectPath: String
        if folderURL.hasPrefix("file://") {
            projectPath = String(folderURL.dropFirst(7)).removingPercentEncoding ?? folderURL
        } else {
            projectPath = folderURL
        }

        let projectName = (projectPath as NSString).lastPathComponent

        // Get composers for this date
        let composers = getComposersForDate(dbPath: stateDBPath, startTs: startTs, endTs: endTs)
        guard !composers.isEmpty else { continue }

        print("Project: \(projectName)")
        print("  Path: \(projectPath)")
        print("  Composers: \(composers.count)")

        // Get messages for each composer
        var projectMessageCount = 0
        var composerNames: [String] = []

        for composer in composers {
            let messages = getMessagesForComposer(
                globalDBPath: globalDBPath,
                composerId: composer.id,
                startOfDay: startOfDay,
                endOfDay: endOfDay
            )

            projectMessageCount += messages.count
            composerNames.append(composer.name ?? composer.id)

            if messages.count > 0 {
                print("    Composer '\(composer.name ?? "unnamed")': \(messages.count) messages")

                // Show first few messages
                for msg in messages.prefix(3) {
                    let timeStr = msg.timestamp.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium) } ?? "?"
                    let preview = String(msg.content.prefix(80)).replacingOccurrences(of: "\n", with: " ")
                    print("      [\(timeStr)] \(msg.role): \(preview)...")
                }
                if messages.count > 3 {
                    print("      ... and \(messages.count - 3) more")
                }
            }
        }

        totalMessages += projectMessageCount
        projectsWithActivity.append((projectName, projectMessageCount, composerNames))
        print()
    }

    print("=== Summary ===")
    print("Projects with activity: \(projectsWithActivity.count)")
    print("Total messages: \(totalMessages)")
    for project in projectsWithActivity {
        print("  \(project.name): \(project.messages) msgs in \(project.composers.count) composers")
    }
}

struct ComposerInfo {
    let id: String
    let name: String?
    let createdAt: Double
    let lastUpdatedAt: Double
}

func getComposersForDate(dbPath: String, startTs: Double, endTs: Double) -> [ComposerInfo] {
    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
    guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_close(db) }

    let query = "SELECT value FROM ItemTable WHERE key = 'composer.composerData'"
    var stmt: OpaquePointer?

    guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }

    guard sqlite3_step(stmt) == SQLITE_ROW,
          let valuePtr = sqlite3_column_blob(stmt, 0) else { return [] }

    let valueLength = sqlite3_column_bytes(stmt, 0)
    let data = Data(bytes: valuePtr, count: Int(valueLength))

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let allComposers = json["allComposers"] as? [[String: Any]] else {
        return []
    }

    var composers: [ComposerInfo] = []

    for composer in allComposers {
        guard let composerId = composer["composerId"] as? String else { continue }

        let createdAt = composer["createdAt"] as? Double ?? 0
        let lastUpdatedAt = composer["lastUpdatedAt"] as? Double ?? createdAt

        // Check if overlaps with date range
        let overlaps = (createdAt < endTs && lastUpdatedAt >= startTs)
        guard overlaps else { continue }

        let name = composer["name"] as? String

        composers.append(ComposerInfo(
            id: composerId,
            name: name,
            createdAt: createdAt,
            lastUpdatedAt: lastUpdatedAt
        ))
    }

    return composers
}

struct ChatMessage {
    let role: String
    let content: String
    let timestamp: Date?
}

func getMessagesForComposer(globalDBPath: String, composerId: String, startOfDay: Date, endOfDay: Date) -> [ChatMessage] {
    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
    guard sqlite3_open_v2(globalDBPath, &db, flags, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_close(db) }

    let query = "SELECT value FROM cursorDiskKV WHERE key LIKE ?"
    var stmt: OpaquePointer?

    guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }

    let pattern = "bubbleId:\(composerId):%"
    let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT)

    var messages: [ChatMessage] = []

    while sqlite3_step(stmt) == SQLITE_ROW {
        guard let valuePtr = sqlite3_column_blob(stmt, 0) else { continue }
        let valueLength = sqlite3_column_bytes(stmt, 0)
        let data = Data(bytes: valuePtr, count: Int(valueLength))

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            continue
        }

        // Parse type: 1=user, 2=assistant
        guard let type = json["type"] as? Int, type == 1 || type == 2 else { continue }

        // Parse createdAt (ISO 8601 string with fractional seconds)
        var timestamp: Date?
        if let createdAtStr = json["createdAt"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            timestamp = formatter.date(from: createdAtStr)
        }

        // Filter by date if we have a timestamp
        if let ts = timestamp {
            guard ts >= startOfDay && ts < endOfDay else { continue }
        }

        // Get text content
        let text = json["text"] as? String ?? ""
        guard !text.isEmpty else { continue }

        let role = type == 1 ? "user" : "assistant"
        messages.append(ChatMessage(role: role, content: text, timestamp: timestamp))
    }

    // Sort by timestamp
    messages.sort { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }

    return messages
}

// MARK: - Main

let args = CommandLine.arguments
let dateString = args.count > 1 ? args[1] : nil

testCursorDB(dateString: dateString)
