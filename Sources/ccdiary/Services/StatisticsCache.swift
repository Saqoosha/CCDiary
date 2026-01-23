import Foundation
import os.log

private let logger = Logger(subsystem: "ccdiary", category: "StatisticsCache")

/// Service for caching DayStatistics to speed up loading
actor StatisticsCache {
    private let cacheDirectory: URL
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesDir.appendingPathComponent("ccdiary/statistics", isDirectory: true)

        // Create directory if needed
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Get cached statistics for a date, returns nil if not cached
    func get(for dateString: String) -> DayStatistics? {
        let fileURL = cacheDirectory.appendingPathComponent("\(dateString).json")

        do {
            let data = try Data(contentsOf: fileURL)
            let statistics = try decoder.decode(DayStatistics.self, from: data)
            logger.debug("Cache hit for \(dateString)")
            return statistics
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // File not found is expected - no need to log
            return nil
        } catch {
            logger.warning("Failed to read cache for \(dateString): \(error.localizedDescription)")
            return nil
        }
    }

    /// Save statistics to cache
    func save(_ statistics: DayStatistics) {
        let fileURL = cacheDirectory.appendingPathComponent("\(statistics.isoDateString).json")

        do {
            let data = try encoder.encode(statistics)
            try data.write(to: fileURL)
            logger.debug("Cached statistics for \(statistics.isoDateString)")
        } catch {
            logger.error("Failed to cache statistics for \(statistics.isoDateString): \(error.localizedDescription)")
        }
    }

    /// Check if a date should be cached (only past dates, not today)
    static func shouldCache(date: Date) -> Bool {
        let calendar = Calendar.current
        return !calendar.isDateInToday(date)
    }

    /// Clear all cached statistics
    func clearAll() {
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
}
