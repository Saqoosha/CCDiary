import Foundation
import os.log

private let logger = Logger(subsystem: "CCDiary", category: "HostStatsFetchService")

actor HostStatsFetchService {
    struct FetchResult: Sendable {
        let date: String
        let hosts: [HostStatsPayload]
    }

    func fetch(date: String, endpoint: URL, token: String) async throws -> FetchResult {
        guard !token.isEmpty else { throw HostStatsFetchError.missingToken }

        var components = URLComponents(url: endpoint.appendingPathComponent("api/host-stats"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "date", value: date)]
        guard let url = components?.url else {
            throw HostStatsFetchError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HostStatsFetchError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let snippet = String(data: data, encoding: .utf8) ?? "<unreadable>"
            throw HostStatsFetchError.apiError(statusCode: httpResponse.statusCode, message: snippet)
        }

        let decoder = JSONDecoder()
        struct Response: Codable {
            let date: String
            let hosts: [HostStatsPayload]
        }
        let decoded = try decoder.decode(Response.self, from: data)
        logger.notice("fetched \(decoded.hosts.count) host stats for \(date, privacy: .public)")
        return FetchResult(date: decoded.date, hosts: decoded.hosts)
    }
}

enum HostStatsFetchError: LocalizedError {
    case missingToken
    case invalidURL
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingToken: return "Cloud ingest token not configured"
        case .invalidURL: return "Invalid URL for host stats fetch"
        case .invalidResponse: return "Invalid response from host stats endpoint"
        case .apiError(let code, let msg): return "Host stats fetch error (\(code)): \(msg)"
        }
    }
}
