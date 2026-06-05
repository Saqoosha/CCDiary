import Foundation
import os.log

/// Service for storing and loading diary entries
actor DiaryStorage {
    private let diariesDirectory: URL
    private static let legacyDirectoryName = "ccdiary"
    private static let newDirectoryName = "CCDiary"
    private static let logger = Logger(subsystem: "CCDiary", category: "DiaryStorage")

    init() {
        // Store under ~/Library/Application Support/CCDiary, *outside* the
        // TCC-protected ~/Documents folder. This keeps the 4am LaunchAgent from
        // ever triggering a "allow access to Documents" dialog that would stall
        // the unattended run.
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.diariesDirectory = home.appendingPathComponent("Library/Application Support/\(Self.newDirectoryName)")

        // Migrate diaries from older ~/Documents locations once. Guarded by a marker
        // so we never probe ~/Documents again — even a `fileExists` on a Documents
        // subpath trips the TCC "access your Documents folder" prompt, which would
        // stall the headless 04:00 agent. The whole point of this storage move is to
        // stay out of Documents, so the probe must be one-and-done.
        Self.migrateFromLegacyLocationsIfNeeded(to: diariesDirectory)
        Self.migrateFromFlatLayout(in: diariesDirectory)
    }

    init(directory: URL) {
        self.diariesDirectory = directory
        Self.migrateFromFlatLayout(in: diariesDirectory)
    }

    /// Migrate diaries from older ~/Documents locations into the current directory.
    ///
    /// Location history (oldest → newest):
    ///   1. ~/Documents/ccdiary  (flat: YYYY-MM-DD.md at the root)
    ///   2. ~/Documents/CCDiary  (nested: YYYY/MM/YYYY-MM-DD.md)
    ///   3. ~/Library/Application Support/CCDiary  (current — outside TCC-protected Documents)
    ///
    /// Only date-named diary files (`YYYY-MM-DD.md` regular files) are *moved*, never
    /// overwriting an existing destination — so unrelated Markdown (e.g. a stray
    /// `README.md`) and `.md`-suffixed directories are left alone. Source #1 is flat and
    /// source #2 is nested, so same-date files from the two sources land at different
    /// paths and don't collide here; `migrateFromFlatLayout` then merges them, keeping
    /// the newer by mtime. Empty legacy trees (including `.DS_Store`-only ones) are
    /// cleaned up afterward. Every move is logged so a partial migration is diagnosable.
    /// Marker file (inside the TCC-free Application Support dir) recording that the
    /// one-time `~/Documents` migration has already run. Once it exists, we skip the
    /// migration entirely and never touch `~/Documents` again — so a headless run
    /// can't trip a TCC permission prompt. Probing `~/Documents` (even `fileExists`)
    /// is exactly what we must avoid on every launch after the first.
    private static let migrationMarkerName = ".legacy-migration-done"

    private static func migrateFromLegacyLocationsIfNeeded(to newDir: URL) {
        let fileManager = FileManager.default
        let marker = newDir.appendingPathComponent(migrationMarkerName)
        guard !fileManager.fileExists(atPath: marker.path) else { return }

        migrateFromLegacyLocations(to: newDir)

        // Record completion so subsequent launches never probe ~/Documents again.
        // newDir lives under Application Support (TCC-free); creating it and the
        // marker here is safe even when no diaries were migrated.
        //
        // We write the marker even if the migration above was only partial (some
        // moveItem calls failed, or ~/Documents couldn't be enumerated at all).
        // This is deliberate, not an oversight: gating the marker on full success
        // would mean a Mac that permanently denies ~/Documents access — exactly the
        // headless-TCC case this guard exists for — never writes the marker, re-probes
        // ~/Documents on every launch, and re-arms the very prompt that stalls the
        // 04:00 run. The cost is bounded: moveItem is non-destructive, so any file
        // that failed to migrate stays put in ~/Documents (never lost) and each
        // failure is logged per-file in migrateFromLegacyLocations for manual recovery.
        //
        // If the marker itself can't be written we surface it: without it every launch
        // re-probes ~/Documents, so a silent failure here would defeat the whole guard.
        do {
            try fileManager.createDirectory(at: newDir, withIntermediateDirectories: true)
        } catch {
            logger.error("migration: cannot create \(newDir.path, privacy: .public) for marker: \(error.localizedDescription, privacy: .public) — ~/Documents will be probed again next launch (TCC prompt risk)")
            return
        }
        if !fileManager.createFile(atPath: marker.path, contents: nil) {
            logger.error("migration: failed to write marker at \(marker.path, privacy: .public) — ~/Documents will be probed again next launch (TCC prompt risk)")
        }
    }

    private static func migrateFromLegacyLocations(to newDir: URL) {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let legacyDirs = [
            home.appendingPathComponent("Documents/\(legacyDirectoryName)"),
            home.appendingPathComponent("Documents/\(newDirectoryName)"),
        ]

        for legacyDir in legacyDirs {
            guard fileManager.fileExists(atPath: legacyDir.path),
                  legacyDir.resolvingSymlinksInPath() != newDir.resolvingSymlinksInPath() else { continue }

            do {
                try fileManager.createDirectory(at: newDir, withIntermediateDirectories: true)
            } catch {
                // If we can't create the destination, every move below would silently
                // no-op and the app would read an empty store — abort loudly instead.
                logger.error("migration: cannot create \(newDir.path, privacy: .public): \(error.localizedDescription, privacy: .public) — leaving \(legacyDir.path, privacy: .public) untouched")
                continue
            }

            guard let enumerator = fileManager.enumerator(
                at: legacyDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                logger.error("migration: cannot enumerate \(legacyDir.path, privacy: .public)")
                continue
            }

            // Collect first, then move — never mutate the directory tree mid-enumeration
            // (moving a file out from under a live enumerator is undefined behavior).
            var moves: [(source: URL, destination: URL)] = []
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "md" {
                let dateString = fileURL.deletingPathExtension().lastPathComponent
                let isRegularFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
                guard isRegularFile, isDateString(dateString) else { continue }
                // Preserve the relative sub-path (YYYY/MM/…) under the new directory.
                let prefix = legacyDir.path + "/"
                let relativePath = fileURL.path.hasPrefix(prefix)
                    ? String(fileURL.path.dropFirst(prefix.count))
                    : fileURL.lastPathComponent
                moves.append((fileURL, newDir.appendingPathComponent(relativePath)))
            }

            var moved = 0, skipped = 0, failed = 0
            for (source, destination) in moves {
                guard !fileManager.fileExists(atPath: destination.path) else { skipped += 1; continue }
                do {
                    try fileManager.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.moveItem(at: source, to: destination)
                    moved += 1
                } catch {
                    logger.error("migration: failed to move \(source.path, privacy: .public) -> \(destination.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    failed += 1
                }
            }

            if moved > 0 || failed > 0 {
                logger.notice("migration from \(legacyDir.path, privacy: .public): moved \(moved) skipped \(skipped) failed \(failed)")
            }

            Self.removeEmptyDirectoryTree(at: legacyDir)
        }
    }

    /// Recursively remove empty subdirectories, then the directory itself if nothing
    /// but ignorable cruft (a stray `.DS_Store`) remains — so a Finder-touched legacy
    /// folder still gets cleaned up. Best-effort: directories still holding a real file
    /// are left untouched, so we never delete data out from under a non-diary file.
    private static func removeEmptyDirectoryTree(at url: URL) {
        let fileManager = FileManager.default
        if let contents = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) {
            for item in contents {
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir { removeEmptyDirectoryTree(at: item) }
            }
        }
        if let remaining = try? fileManager.contentsOfDirectory(atPath: url.path),
           remaining.allSatisfy({ $0 == ".DS_Store" }) {
            try? fileManager.removeItem(at: url)
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
