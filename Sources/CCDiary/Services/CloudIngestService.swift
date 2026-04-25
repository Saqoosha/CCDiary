import Foundation
import os.log

private let logger = Logger(subsystem: "CCDiary", category: "CloudIngestService")

/// Posts generated diaries to the Cloudflare Worker (`POST /api/diaries`).
///
/// Sibling of `SlackService`. The endpoint is idempotent (D1 upsert keyed by
/// date), so retrying after a transient failure is always safe.
actor CloudIngestService {
    func upload(
        _ entry: DiaryEntry,
        stats: DayStatistics?,
        provider: AIProvider,
        model: String,
        endpoint: URL,
        token: String
    ) async throws -> CloudIngestResult {
        guard !token.isEmpty else { throw CloudIngestError.missingToken }

        let url = endpoint.appendingPathComponent("api/diaries")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let body = makePayload(entry: entry, stats: stats, provider: provider, model: model)
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudIngestError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let snippet = String(data: data, encoding: .utf8) ?? "<unreadable>"
            throw CloudIngestError.apiError(statusCode: httpResponse.statusCode, message: snippet)
        }

        let inserted: Bool
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let flag = json["inserted"] as? Bool {
                inserted = flag
            } else {
                inserted = httpResponse.statusCode == 201
            }
        } catch {
            // Server returned 2xx but not JSON we recognize. Fall back to the
            // status code so the CLI doesn't lie about insert vs update, and
            // log enough to diagnose the API drift later.
            logger.warning("cloud response not JSON (status \(httpResponse.statusCode)): \(error.localizedDescription)")
            inserted = httpResponse.statusCode == 201
        }

        logger.notice("uploaded diary \(entry.dateString, privacy: .public) (\(inserted ? "inserted" : "updated", privacy: .public))")
        return CloudIngestResult(date: entry.dateString, inserted: inserted, statusCode: httpResponse.statusCode)
    }

    private func makePayload(
        entry: DiaryEntry,
        stats: DayStatistics?,
        provider: AIProvider,
        model: String
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "date": entry.dateString,
            "markdown": entry.markdown,
            "generated_at": Int(entry.generatedAt.timeIntervalSince1970 * 1000),
            "provider": payloadProviderName(provider),
            "model": model,
            "source": "cli",
        ]
        if let stats {
            payload["stats"] = makeStatsPayload(stats)
        }
        return payload
    }

    private func makeStatsPayload(_ stats: DayStatistics) -> [String: Any] {
        let topProject = stats.projects.max(by: { $0.messageCount < $1.messageCount })
        let activeMinutes = stats.projects.reduce(0) { $0 + $1.durationMinutes }
        let peakHour = computePeakHour(projects: stats.projects)

        return [
            "sessions": stats.sessionCount,
            "messages": stats.messageCount,
            "project_count": stats.projectCount,
            "active_minutes": activeMinutes,
            "peak_hour": peakHour as Any,
            "top_project": topProject?.name as Any,
            "sources": [
                "claudeCode": [
                    "sessions": stats.ccSessionCount,
                    "messages": stats.ccMessageCount,
                ],
                "cursor": [
                    "sessions": stats.cursorSessionCount,
                    "messages": stats.cursorMessageCount,
                ],
                "codex": [
                    "sessions": stats.codexSessionCount,
                    "messages": stats.codexMessageCount,
                ],
            ],
            "projects": stats.projects.map(projectSummaryToDict),
        ]
    }

    /// Distribute each project's messages across the hours its time range spans,
    /// then pick the hour with the highest weighted count. Returns nil when no
    /// project has a usable time range. Handles midnight-crossing ranges
    /// (e.g. 23:00 → 02:00 spans 4 hours: 23, 0, 1, 2 — not 22).
    private func computePeakHour(projects: [ProjectSummary]) -> Int? {
        var hourWeights = [Int](repeating: 0, count: 24)
        let calendar = Calendar.current
        for project in projects {
            let startHour = calendar.component(.hour, from: project.timeRangeStart)
            let endHour = calendar.component(.hour, from: project.timeRangeEnd)
            let hours = hourRange(startHour: startHour, endHour: endHour)
            guard !hours.isEmpty else { continue }
            let perHour = max(project.messageCount / hours.count, 1)
            for h in hours where h >= 0 && h < 24 {
                hourWeights[h] += perHour
            }
        }
        guard let max = hourWeights.enumerated().max(by: { $0.element < $1.element }),
              max.element > 0 else { return nil }
        return max.offset
    }

    /// Inclusive list of hour-of-day values touched by a range. Wraps around
    /// midnight when `endHour < startHour`.
    private func hourRange(startHour: Int, endHour: Int) -> [Int] {
        guard startHour >= 0, startHour < 24, endHour >= 0, endHour < 24 else { return [] }
        if endHour >= startHour {
            return Array(startHour...endHour)
        }
        return Array(startHour...23) + Array(0...endHour)
    }

    private func projectSummaryToDict(_ project: ProjectSummary) -> [String: Any] {
        [
            "name": project.name,
            "path": project.path,
            "messageCount": project.messageCount,
            "timeRangeStart": project.timeRangeStart.formatted(.iso8601),
            "timeRangeEnd": project.timeRangeEnd.formatted(.iso8601),
            "source": project.source.rawValue,
        ]
    }

    /// Match the Worker's expected provider tags. The Worker stores it as text
    /// only — used for the "Favorite provider" stat — so any consistent name works.
    private func payloadProviderName(_ provider: AIProvider) -> String {
        switch provider {
        case .claudeAPI: return "claude"
        case .gemini:    return "gemini"
        case .openai:    return "openai"
        }
    }
}

struct CloudIngestResult: Sendable {
    let date: String
    let inserted: Bool
    let statusCode: Int
}

enum CloudIngestError: LocalizedError, Sendable {
    case missingToken
    case missingEndpoint
    case invalidEndpoint(String)
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Cloud ingest token not configured (set CCDIARY_CLOUD_TOKEN or store in Keychain service \(KeychainHelper.cloudTokenService))"
        case .missingEndpoint:
            return "Cloud ingest endpoint not configured (pass --cloud-endpoint URL or set CCDIARY_CLOUD_ENDPOINT)"
        case .invalidEndpoint(let raw):
            return "Cloud ingest endpoint is not a valid URL: \(raw)"
        case .invalidResponse:
            return "Invalid response from cloud ingest endpoint"
        case .apiError(let statusCode, let message):
            return "Cloud ingest error (\(statusCode)): \(message)"
        }
    }
}

