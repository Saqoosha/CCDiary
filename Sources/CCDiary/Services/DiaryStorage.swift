import Foundation

/// Service for storing and loading diary entries
actor DiaryStorage {
    private let diariesDirectory: URL
    private static let legacyDirectoryName = "ccdiary"
    private static let newDirectoryName = "CCDiary"

    init() {
        // Default to ~/Documents/CCDiary/ (macOS standard for user documents)
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.diariesDirectory = home.appendingPathComponent("Documents/\(Self.newDirectoryName)")

        // Migrate from legacy directory if needed
        Self.migrateFromLegacyDirectory()
        Self.migrateFromFlatLayout(in: diariesDirectory)
    }

    init(directory: URL) {
        self.diariesDirectory = directory
        Self.migrateFromFlatLayout(in: diariesDirectory)
    }

    /// Migrate diaries from legacy ~/Documents/ccdiary to ~/Documents/CCDiary
    private static func migrateFromLegacyDirectory() {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let legacyDir = home.appendingPathComponent("Documents/\(legacyDirectoryName)")
        let newDir = home.appendingPathComponent("Documents/\(newDirectoryName)")

        // Skip if legacy directory doesn't exist
        guard fileManager.fileExists(atPath: legacyDir.path) else { return }

        // Create new directory if needed
        try? fileManager.createDirectory(at: newDir, withIntermediateDirectories: true)

        // Move all files from legacy to new directory
        if let files = try? fileManager.contentsOfDirectory(at: legacyDir, includingPropertiesForKeys: nil) {
            for file in files {
                let destURL = newDir.appendingPathComponent(file.lastPathComponent)
                // Only move if destination doesn't exist (don't overwrite newer files)
                if !fileManager.fileExists(atPath: destURL.path) {
                    try? fileManager.moveItem(at: file, to: destURL)
                }
            }
        }

        // Remove legacy directory if empty
        if let remaining = try? fileManager.contentsOfDirectory(at: legacyDir, includingPropertiesForKeys: nil),
           remaining.isEmpty {
            try? fileManager.removeItem(at: legacyDir)
        }
    }

    /// Ensure directory exists
    private static func ensureDirectoryExists(at directory: URL) throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    /// Build YYYY/MM directory path from YYYY-MM-DD date string
    private static func diaryDirectory(for dateString: String, in diariesDirectory: URL) -> URL {
        let year = String(dateString.prefix(4))
        let month = String(dateString.dropFirst(5).prefix(2))

        return diariesDirectory
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)
    }

    /// Build YYYY/MM directory path from YYYY-MM-DD date string
    private func diaryDirectory(for dateString: String) -> URL {
        Self.diaryDirectory(for: dateString, in: diariesDirectory)
    }

    /// New storage path (YYYY/MM/YYYY-MM-DD.md)
    private static func diaryFileURL(for dateString: String, in diariesDirectory: URL) -> URL {
        diaryDirectory(for: dateString, in: diariesDirectory)
            .appendingPathComponent("\(dateString).md")
    }

    /// New storage path (YYYY/MM/YYYY-MM-DD.md)
    private func diaryFileURL(for dateString: String) -> URL {
        Self.diaryFileURL(for: dateString, in: diariesDirectory)
    }

    /// Legacy storage path (YYYY-MM-DD.md directly under root)
    private func legacyDiaryFileURL(for dateString: String) -> URL {
        diariesDirectory.appendingPathComponent("\(dateString).md")
    }

    /// Validate YYYY-MM-DD format
    private static func isDateString(_ value: String) -> Bool {
        value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    /// Migrate flat files from root to YYYY/MM/YYYY-MM-DD.md layout
    private static func migrateFromFlatLayout(in diariesDirectory: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: diariesDirectory.path) else { return }

        guard let files = try? fileManager.contentsOfDirectory(
            at: diariesDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for fileURL in files where fileURL.pathExtension == "md" {
            let dateString = fileURL.deletingPathExtension().lastPathComponent
            guard isDateString(dateString) else { continue }

            let destinationURL = diaryFileURL(for: dateString, in: diariesDirectory)
            try? ensureDirectoryExists(at: destinationURL.deletingLastPathComponent())

            if fileManager.fileExists(atPath: destinationURL.path) {
                let sourceAttributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
                let destinationAttributes = try? fileManager.attributesOfItem(atPath: destinationURL.path)
                let sourceDate = sourceAttributes?[.modificationDate] as? Date
                let destinationDate = destinationAttributes?[.modificationDate] as? Date

                if let sourceDate, let destinationDate, sourceDate > destinationDate {
                    try? fileManager.removeItem(at: destinationURL)
                    try? fileManager.moveItem(at: fileURL, to: destinationURL)
                } else {
                    try? fileManager.removeItem(at: fileURL)
                }
            } else {
                try? fileManager.moveItem(at: fileURL, to: destinationURL)
            }
        }
    }

    /// Save a diary entry
    func save(_ entry: DiaryEntry) throws {
        let fileURL = diaryFileURL(for: entry.dateString)
        try Self.ensureDirectoryExists(at: fileURL.deletingLastPathComponent())

        try entry.markdown.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Load all diary entries
    func loadAll() throws -> [DiaryEntry] {
        guard FileManager.default.fileExists(atPath: diariesDirectory.path) else {
            return []
        }

        guard let enumerator = FileManager.default.enumerator(
            at: diariesDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var entriesByDate: [String: DiaryEntry] = [:]

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "md" {
            let dateString = fileURL.deletingPathExtension().lastPathComponent
            guard Self.isDateString(dateString) else { continue }

            let markdown = try String(contentsOf: fileURL, encoding: .utf8)
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let modDate = attributes[.modificationDate] as? Date ?? Date()
            let entry = DiaryEntry(
                dateString: dateString,
                markdown: markdown,
                generatedAt: modDate
            )

            if let existing = entriesByDate[dateString], existing.generatedAt >= modDate {
                continue
            }
            entriesByDate[dateString] = entry
        }

        var entries = Array(entriesByDate.values)
        // Sort by date descending
        entries.sort { $0.dateString > $1.dateString }

        return entries
    }

    /// Load a specific diary entry by date
    func load(dateString: String) throws -> DiaryEntry? {
        let nestedFileURL = diaryFileURL(for: dateString)
        let fileURL: URL
        if FileManager.default.fileExists(atPath: nestedFileURL.path) {
            fileURL = nestedFileURL
        } else {
            let legacyFileURL = legacyDiaryFileURL(for: dateString)
            guard FileManager.default.fileExists(atPath: legacyFileURL.path) else {
                return nil
            }
            fileURL = legacyFileURL
        }

        let markdown = try String(contentsOf: fileURL, encoding: .utf8)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let modDate = attributes[.modificationDate] as? Date ?? Date()

        return DiaryEntry(
            dateString: dateString,
            markdown: markdown,
            generatedAt: modDate
        )
    }

    /// Check if diary exists for date
    func exists(dateString: String) -> Bool {
        let nestedFileURL = diaryFileURL(for: dateString)
        let legacyFileURL = legacyDiaryFileURL(for: dateString)
        return FileManager.default.fileExists(atPath: nestedFileURL.path)
            || FileManager.default.fileExists(atPath: legacyFileURL.path)
    }

    /// Delete a diary entry
    func delete(dateString: String) throws {
        let nestedFileURL = diaryFileURL(for: dateString)
        if FileManager.default.fileExists(atPath: nestedFileURL.path) {
            try FileManager.default.removeItem(at: nestedFileURL)
        }

        let legacyFileURL = legacyDiaryFileURL(for: dateString)
        if FileManager.default.fileExists(atPath: legacyFileURL.path) {
            try FileManager.default.removeItem(at: legacyFileURL)
        }
    }

    /// Get the diaries directory path
    var directoryPath: String {
        diariesDirectory.path
    }
}
