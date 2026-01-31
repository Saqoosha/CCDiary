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
    }

    init(directory: URL) {
        self.diariesDirectory = directory
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
