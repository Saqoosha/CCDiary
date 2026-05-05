import Foundation
import os.log

private let logger = Logger(subsystem: "CCDiary", category: "HostStatsPushService")

actor HostStatsPushService {
    struct Result: Sendable {
        let date: String
        let host: String
        let inserted: Bool
        let statusCode: Int
    }

    func push(_ payload: HostStatsPayload, endpoint: URL, token: String) async throws -> Result {
        guard !token.isEmpty else { throw HostStatsPushError.missingToken }

        let url = endpoint.appendingPathComponent("api/host-stats")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HostStatsPushError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let snippet = String(data: data, encoding: .utf8) ?? "<unreadable>"
            throw HostStatsPushError.apiError(statusCode: httpResponse.statusCode, message: snippet)
        }

        let inserted: Bool
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let flag = json["inserted"] as? Bool {
            inserted = flag
        } else {
            inserted = httpResponse.statusCode == 201
        }

        logger.notice("pushed host stats for \(payload.date, privacy: .public) host \(payload.host, privacy: .public) (\(inserted ? "inserted" : "updated", privacy: .public))")
        return Result(date: payload.date, host: payload.host, inserted: inserted, statusCode: httpResponse.statusCode)
    }
}

enum HostStatsPushError: LocalizedError {
    case missingToken
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingToken: return "Cloud ingest token not configured"
        case .invalidResponse: return "Invalid response from host stats endpoint"
        case .apiError(let code, let msg): return "Host stats error (\(code)): \(msg)"
        }
    }
}
