import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct JevUsageBucket: Codable, Sendable, Equatable {
    public let day: String
    public let requests: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let userEmail: String?
}

public struct JevUsageResponse: Codable, Sendable, Equatable {
    public let buckets: [JevUsageBucket]
}

public struct JevUsageSummary: Sendable, Equatable {
    public let requests: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let accountEmail: String?
    public let updatedAt: Date

    public func toUsageSnapshot() -> UsageSnapshot {
        let totalTokens = self.inputTokens + self.outputTokens
        let rows = [
            ProviderDetailSection.Row.makeRow(
                label: "Requests",
                value: self.requests.formatted(),
                usageValue: Double(self.requests)),
            ProviderDetailSection.Row.makeRow(
                label: "Input tokens",
                value: self.inputTokens.formatted(),
                usageValue: Double(self.inputTokens)),
            ProviderDetailSection.Row.makeRow(
                label: "Output tokens",
                value: self.outputTokens.formatted(),
                usageValue: Double(self.outputTokens)),
            ProviderDetailSection.Row.makeRow(
                label: "Total tokens",
                value: totalTokens.formatted(),
                usageValue: Double(totalTokens)),
        ]
        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            details: [.makeSection(title: "Last 7 days", rows: rows)],
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .jev,
                accountEmail: self.accountEmail,
                accountOrganization: nil,
                loginMethod: "TypeSafe console"))
    }
}

public enum JevUsageError: LocalizedError, Sendable, Equatable {
    case missingCookie
    case loginRequired
    case network(String)
    case parse(String)

    public var errorDescription: String? {
        switch self {
        case .missingCookie: "No TypeSafe console session found. Log in at console.typesafe.ai first."
        case .loginRequired: "TypeSafe console session expired. Log in again."
        case let .network(message): "TypeSafe usage request failed: \(message)"
        case let .parse(message): "Could not parse TypeSafe usage: \(message)"
        }
    }
}

public enum JevUsageFetcher {
    public static let usageURL = URL(string: "https://console.typesafe.ai/api/usage?granularity=day")!

    public static func fetchUsage(
        cookieHeader: String,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: Date = Date()) async throws -> JevUsageSummary
    {
        guard let normalizedCookie = CookieHeaderNormalizer.normalize(cookieHeader) else {
            throw JevUsageError.missingCookie
        }
        var request = URLRequest(url: self.usageURL)
        request.setValue(normalizedCookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await transport.response(for: request)
        switch response.statusCode {
        case 200: break
        case 401, 403: throw JevUsageError.loginRequired
        default: throw JevUsageError.network("HTTP \(response.statusCode)")
        }
        do {
            let payload = try JSONDecoder().decode(JevUsageResponse.self, from: response.data)
            return Self.summarize(payload, now: now)
        } catch {
            throw JevUsageError.parse(error.localizedDescription)
        }
    }

    public static func summarize(_ response: JevUsageResponse, now: Date = Date()) -> JevUsageSummary {
        JevUsageSummary(
            requests: response.buckets.reduce(0) { $0 + $1.requests },
            inputTokens: response.buckets.reduce(0) { $0 + $1.inputTokens },
            outputTokens: response.buckets.reduce(0) { $0 + $1.outputTokens },
            accountEmail: response.buckets.compactMap(\.userEmail).first { !$0.isEmpty },
            updatedAt: now)
    }
}
