import Foundation

/// Service for storing and loading diary entries
actor DiaryStorage {
    private let diariesDirectory: URL

    init() {
        // Default to ~/Desktop/ccdiary/diaries for compatibility with CLI
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.diariesDirectory = home.appendingPathComponent("Desktop/ccdiary/diaries")
    }

    init(directory: URL) {
        self.diariesDirectory = directory
    }

    /// Ensure diaries directory exists
    private func ensureDirectoryExists() throws {
        if !FileManager.default.fileExists(atPath: diariesDirectory.path) {
            try FileManager.default.createDirectory(
                at: diariesDirectory,
                withIntermediateDirectories: true
            )
        }
    }

    /// Save a diary entry
    func save(_ entry: DiaryEntry) throws {
        try ensureDirectoryExists()

        let filename = "\(entry.dateString).md"
        let fileURL = diariesDirectory.appendingPathComponent(filename)

        try entry.markdown.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Load all diary entries
    func loadAll() throws -> [DiaryEntry] {
        guard FileManager.default.fileExists(atPath: diariesDirectory.path) else {
            return []
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: diariesDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )

        var entries: [DiaryEntry] = []

        for fileURL in contents where fileURL.pathExtension == "md" {
            let filename = fileURL.deletingPathExtension().lastPathComponent
            // Expect YYYY-MM-DD format
            guard filename.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
                continue
            }

            let markdown = try String(contentsOf: fileURL, encoding: .utf8)
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let modDate = attributes[.modificationDate] as? Date ?? Date()

            entries.append(DiaryEntry(
                dateString: filename,
                markdown: markdown,
                generatedAt: modDate
            ))
        }

        // Sort by date descending
        entries.sort { $0.dateString > $1.dateString }

        return entries
    }

    /// Load a specific diary entry by date
    func load(dateString: String) throws -> DiaryEntry? {
        let filename = "\(dateString).md"
        let fileURL = diariesDirectory.appendingPathComponent(filename)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
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
        let filename = "\(dateString).md"
        let fileURL = diariesDirectory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Delete a diary entry
    func delete(dateString: String) throws {
        let filename = "\(dateString).md"
        let fileURL = diariesDirectory.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Get the diaries directory path
    var directoryPath: String {
        diariesDirectory.path
    }
}
