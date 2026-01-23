import Foundation

@main
struct BenchmarkApp {
    static func main() async {
        do {
            try await runBenchmark()
        } catch {
            print("Error: \(error)")
        }
    }

    static func runBenchmark() async throws {
        let dateString = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "2026-01-22"

        guard let date = DateFormatting.iso.date(from: dateString) else {
            print("Invalid date: \(dateString)")
            return
        }

        print("Benchmarking aggregation for \(dateString)")
        print(String(repeating: "=", count: 50))

        let conversationService = ConversationService()
        let historyService = HistoryService()

        // Build date index first
        print("\nBuilding date index...")
        let indexStart = CFAbsoluteTimeGetCurrent()
        await conversationService.buildFullDateIndex()
        let indexTime = (CFAbsoluteTimeGetCurrent() - indexStart) * 1000
        print("Date index built in \(String(format: "%.1f", indexTime))ms")

        // Read history once
        let allHistory = try await historyService.readHistory()
        let dayHistory = historyService.filterByDate(allHistory, date: date)
        let projectGroups = historyService.groupByProject(dayHistory)

        print("\nFound \(projectGroups.count) projects for \(dateString)")

        // Set up time range
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!.addingTimeInterval(-1)

        // Benchmark without date index
        print("\n--- Without Date Index ---")
        var totalFilesWithout = 0
        var totalMessagesWithout = 0
        let startWithout = CFAbsoluteTimeGetCurrent()

        for (projectPath, _) in projectGroups {
            let files = try await conversationService.findConversationFiles(projectPath: projectPath)
            totalFilesWithout += files.count

            for file in files {
                let entries = try await conversationService.readConversationForDateRange(
                    from: file, start: startOfDay, end: endOfDay
                )
                totalMessagesWithout += entries.count
            }
        }

        let timeWithout = (CFAbsoluteTimeGetCurrent() - startWithout) * 1000
        print("Files processed: \(totalFilesWithout)")
        print("Messages found: \(totalMessagesWithout)")
        print("Time: \(String(format: "%.1f", timeWithout))ms")

        // Benchmark with date index
        print("\n--- With Date Index ---")
        var totalFilesWith = 0
        var totalMessagesWith = 0
        let startWith = CFAbsoluteTimeGetCurrent()

        for (projectPath, _) in projectGroups {
            let allFiles = try await conversationService.findConversationFiles(projectPath: projectPath)
            let relevantFiles = await conversationService.getFilesForDate(dateString, projectFiles: allFiles)
            totalFilesWith += relevantFiles.count

            for file in relevantFiles {
                let entries = try await conversationService.readConversationForDateRange(
                    from: file, start: startOfDay, end: endOfDay
                )
                totalMessagesWith += entries.count
            }
        }

        let timeWith = (CFAbsoluteTimeGetCurrent() - startWith) * 1000
        print("Files processed: \(totalFilesWith)")
        print("Messages found: \(totalMessagesWith)")
        print("Time: \(String(format: "%.1f", timeWith))ms")

        // Summary
        print("\n" + String(repeating: "=", count: 50))
        print("Summary:")
        print("  Without index: \(totalFilesWithout) files, \(String(format: "%.1f", timeWithout))ms")
        print("  With index:    \(totalFilesWith) files, \(String(format: "%.1f", timeWith))ms")
        if timeWith > 0 {
            let speedup = timeWithout / timeWith
            print("  Speedup:       \(String(format: "%.1fx", speedup))")
        }
    }
}
