import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum OpenAIOrgRateLimitsError: Error, LocalizedError, Sendable, Equatable {
    case missingCredential
    case adminKeyRequired
    case rateLimited
    case apiFailure(Int)
    case parseFailure

    public var errorDescription: String? {
        switch self {
        case .missingCredential: "Configure an OpenAI organization Admin API key."
        case .adminKeyRequired: "Organization rate limits require an Admin API key with project read permissions."
        case .rateLimited: "OpenAI organization rate limits are temporarily rate limited."
        case let .apiFailure(code): "OpenAI organization rate limits API failed (HTTP \(code))."
        case .parseFailure: "Could not parse the OpenAI organization rate limits response."
        }
    }
}

public struct OpenAIOrgRateLimitsFetcher: Sendable {
    private let transport: any ProviderHTTPTransport

    public init(transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) {
        self.transport = transport
    }

    public func fetch(environment: [String: String], now: Date = Date()) async throws -> OpenAIOrgRateLimits {
        guard let credential = OpenAIAPIUsageCredential(environment: environment) else {
            throw OpenAIOrgRateLimitsError.missingCredential
        }
        let projects: ([Project], Bool) = try await self.pages(
            path: "/v1/organization/projects",
            credential: credential,
            maximumItems: 25,
            // The schema allows a missing or null status; archived projects are already excluded by default.
            include: { ($0.status ?? "active") == "active" })
        var limits: [String: OpenAIOrgRateLimits.Limit] = [:]
        // Deliberately organization-wide: credential.projectID never scopes this discovery.
        for project in projects.0 {
            let rows: ([RateLimit], Bool) = try await self.pages(
                path: "/v1/organization/projects/\(project.id)/rate_limits", credential: credential)
            for row in rows.0 {
                let model = row.model.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !model.isEmpty, (row.tpm ?? 0) >= 0, (row.rpm ?? 0) >= 0 else {
                    throw OpenAIOrgRateLimitsError.parseFailure
                }
                // Live rows omit either limit for some models (e.g. video models have no token limit).
                guard let tpm = row.tpm, tpm > 0 else { continue }
                let previous = limits[model]
                let rowRPM = row.rpm.flatMap { $0 > 0 ? $0 : nil }
                let rpm = [previous?.requestsPerMinute, rowRPM].compactMap(\.self).max()
                limits[model] = .init(
                    tokensPerMinute: max(previous?.tokensPerMinute ?? 0, tpm),
                    requestsPerMinute: rpm)
            }
        }
        return .init(byModel: limits, projectsSampled: projects.0.count, truncated: projects.1, fetchedAt: now)
    }

    private func pages<Row: Decodable & Sendable>(
        path: String,
        credential: OpenAIAPIUsageCredential,
        maximumItems: Int? = nil,
        include: (Row) -> Bool = { _ in true }) async throws -> ([Row], Bool)
    {
        var rows: [Row] = []
        var cursor: String?
        var seen: Set<String> = []
        for _ in 0..<20 {
            try Task.checkCancellation()
            var url = URLComponents()
            url.scheme = "https"
            url.host = "api.openai.com"
            url.path = path
            url.queryItems = [URLQueryItem(name: "limit", value: "100")]
            if let cursor { url.queryItems?.append(URLQueryItem(name: "after", value: cursor)) }
            var request = URLRequest(url: url.url!)
            request.timeoutInterval = 20
            request.setValue("Bearer \(credential.apiKey)", forHTTPHeaderField: "Authorization")
            let response = try await self.transport.response(for: request)
            switch response.statusCode {
            case 200..<300: break
            case 401, 403: throw OpenAIOrgRateLimitsError.adminKeyRequired
            case 429: throw OpenAIOrgRateLimitsError.rateLimited
            default: throw OpenAIOrgRateLimitsError.apiFailure(response.statusCode)
            }
            let page: Page<Row>
            do {
                page = try JSONDecoder().decode(Page<Row>.self, from: response.data)
            } catch {
                throw OpenAIOrgRateLimitsError.parseFailure
            }
            for row in page.data where include(row) {
                if let maximumItems, rows.count == maximumItems { return (rows, true) }
                rows.append(row)
            }
            if !page.hasMore { return (rows, false) }
            if let maximumItems, rows.count == maximumItems { return (rows, true) }
            guard let next = page.lastID, !next.isEmpty, seen.insert(next).inserted else {
                throw OpenAIOrgRateLimitsError.parseFailure
            }
            cursor = next
        }
        throw OpenAIOrgRateLimitsError.parseFailure
    }
}

private struct Project: Decodable, Sendable {
    let id: String
    let status: String?
}

private struct RateLimit: Decodable, Sendable {
    let model: String
    let tpm: Int?
    let rpm: Int?

    enum CodingKeys: String, CodingKey {
        case model, tpm = "max_tokens_per_1_minute", rpm = "max_requests_per_1_minute"
    }
}

private struct Page<Row: Decodable & Sendable>: Decodable {
    let data: [Row]
    let hasMore: Bool
    let lastID: String?

    enum CodingKeys: String, CodingKey {
        case data, hasMore = "has_more", lastID = "last_id"
    }
}
