import Foundation

/// Result of parsing JSONL files with error tracking
struct ParseResult<T> {
    let entries: [T]
    let skippedCount: Int
    let errors: [String]

    var hasWarnings: Bool { skippedCount > 0 }

    init(entries: [T], skippedCount: Int = 0, errors: [String] = []) {
        self.entries = entries
        self.skippedCount = skippedCount
        self.errors = errors
    }
}
