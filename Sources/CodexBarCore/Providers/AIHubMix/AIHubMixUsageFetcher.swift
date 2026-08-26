import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AIHubMixUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case invalidCredentials
    case apiError(String)
    case parseFailed(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing AIHubMix Manage Key. Add one in Settings or set AIHUBMIX_ACCESS_KEY. "
                + "Inference API keys (sk-) are not accepted."
        case .invalidCredentials:
            "AIHubMix rejected the Manage Key. Use a System Access Token from AIHubMix Settings, "
                + "not an inference API key."
        case let .apiError(message):
            "AIHubMix API error: \(message)"
        case let .parseFailed(message):
            "Could not parse AIHubMix usage: \(message)"
        case let .networkError(message):
            "AIHubMix network error: \(message)"
        }
    }
}

public struct AIHubMixUsageSnapshot: Sendable, Equatable {
    public static let quotaUnitsPerUSD: Double = 500_000

    public let remainingUSD: Double
    public let usedUSD: Double
    public let requestCount: Int?
    public let email: String?
    public let displayName: String?
    public let username: String?
    public let updatedAt: Date

    public func toUsageSnapshot() -> UsageSnapshot {
        var rows: [ProviderDetailSection.Row] = [
            .makeRow(label: "Used", value: UsageFormatter.usdString(self.usedUSD)),
        ]
        if let requestCount {
            rows.append(.makeRow(
                label: "Requests",
                value: requestCount.formatted(.number.locale(Locale(identifier: "en_US")))))
        }

        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            details: [.makeSection(title: "Account", rows: rows)],
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .aihubmix,
                accountEmail: self.email,
                accountOrganization: self.displayName ?? self.username,
                loginMethod: "Balance: \(UsageFormatter.usdString(self.remainingUSD))"),
            dataConfidence: .exact)
    }
}

private struct AIHubMixSelfResponse: Decodable {
    let success: Bool?
    let message: String?
    let data: AIHubMixUserData?
}

private struct AIHubMixUserData: Decodable {
    let username: String?
    let displayName: String?
    let email: String?
    let quota: Double?
    let usedQuota: Double?
    let requestCount: Int?

    enum CodingKeys: String, CodingKey {
        case username
        case displayName = "display_name"
        case email
        case quota
        case usedQuota = "used_quota"
        case requestCount = "request_count"
    }
}

public enum AIHubMixUsageFetcher {
    private static let log = CodexBarLog.logger(LogCategories.provider(.aihubmix, scope: "usage"))
    private static let timeoutSeconds: TimeInterval = 15

    public static func fetchUsage(
        apiKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: Date = Date()) async throws -> AIHubMixUsageSnapshot
    {
        let token = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw AIHubMixUsageError.missingCredentials }
        try AIHubMixSettingsReader.validateEndpointOverrides(environment: environment)

        var request = URLRequest(url: self.selfURL(baseURL: AIHubMixSettingsReader.apiURL(environment: environment)))
        request.httpMethod = "GET"
        request.timeoutInterval = self.timeoutSeconds
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")

        let response: ProviderHTTPResponse
        do {
            response = try await transport.response(for: request, retryPolicy: .transientIdempotent)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw AIHubMixUsageError.networkError(error.localizedDescription)
        }

        switch response.statusCode {
        case 200..<300:
            return try self.parseSnapshot(data: response.data, now: now)
        case 401, 403:
            throw AIHubMixUsageError.invalidCredentials
        default:
            Self.log.error("AIHubMix API returned HTTP \(response.statusCode)")
            throw AIHubMixUsageError.apiError("HTTP \(response.statusCode)")
        }
    }

    static func parseSnapshot(data: Data, now: Date = Date()) throws -> AIHubMixUsageSnapshot {
        let decoded: AIHubMixSelfResponse
        do {
            decoded = try JSONDecoder().decode(AIHubMixSelfResponse.self, from: data)
        } catch {
            throw AIHubMixUsageError.parseFailed(error.localizedDescription)
        }

        guard decoded.success == true else {
            let message = Self.nonEmpty(decoded.message) ?? "request failed"
            throw AIHubMixUsageError.apiError(message)
        }
        guard let user = decoded.data, let quota = user.quota, let usedQuota = user.usedQuota else {
            throw AIHubMixUsageError.parseFailed("Missing AIHubMix user payload")
        }

        return AIHubMixUsageSnapshot(
            remainingUSD: quota / AIHubMixUsageSnapshot.quotaUnitsPerUSD,
            usedUSD: usedQuota / AIHubMixUsageSnapshot.quotaUnitsPerUSD,
            requestCount: user.requestCount,
            email: Self.nonEmpty(user.email),
            displayName: Self.nonEmpty(user.displayName),
            username: Self.nonEmpty(user.username),
            updatedAt: now)
    }

    private static func selfURL(baseURL: URL) -> URL {
        baseURL.appending(path: "api").appending(path: "user").appending(path: "self")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
