import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ClaudeOAuthFetchError: LocalizedError, Sendable {
    case unauthorized
    case rateLimited(retryAfter: Date?)
    case invalidResponse
    case serverError(Int, String?)
    case networkError(Error)

    public static let usageRateLimitDescription =
        "Claude OAuth usage endpoint is rate limited by Anthropic right now. Wait a few minutes, "
            + "then click Refresh. If it keeps happening, run `claude logout && claude login`, then try again."

    public static func isUsageRateLimitDescription(_ description: String?) -> Bool {
        description == self.usageRateLimitDescription
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        if let fetchError = error as? ClaudeOAuthFetchError,
           case let .networkError(underlying) = fetchError
        {
            return self.isCancellation(underlying)
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Claude OAuth request unauthorized. Run `claude` to re-authenticate."
        case .rateLimited:
            return Self.usageRateLimitDescription
        case .invalidResponse:
            return "Claude OAuth response was invalid."
        case let .serverError(code, body):
            if let body, !body.isEmpty {
                let cleaned = body
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let shortened = cleaned.count > 400 ? String(cleaned.prefix(400)) + "…" : cleaned
                return "Claude OAuth error: HTTP \(code) – \(shortened)"
            }
            return "Claude OAuth error: HTTP \(code)"
        case let .networkError(error):
            return "Claude OAuth network error: \(error.localizedDescription)"
        }
    }
}

enum ClaudeOAuthUsageFetcher {
    private static let baseURL = "https://api.anthropic.com"
    private static let usageTransport = ProviderHTTPClient(
        session: ProviderHTTPClient.redirectGuardedSession(configuration: Self.usageSessionConfiguration()))
    private static let usagePath = "/api/oauth/usage"
    private static let profilePath = "/api/oauth/profile"
    private static let betaHeader = "oauth-2025-04-20"
    private static let fallbackClaudeCodeVersion = "2.1.0"

    static func fetchUsage(
        accessToken: String,
        detectClaudeVersion: Bool = true,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any ProviderHTTPTransport = ClaudeOAuthUsageFetcher
            .usageTransport) async throws -> OAuthUsageResponse
    {
        if let blockedUntil = ClaudeOAuthUsageRateLimitGate.blockedUntil(accessToken: accessToken) {
            throw ClaudeOAuthFetchError.rateLimited(retryAfter: blockedUntil)
        }

        guard let url = URL(string: baseURL + usagePath + "?cedar_ember=1") else {
            throw ClaudeOAuthFetchError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // OAuth usage endpoint currently requires the beta header.
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        let userAgent = Self.claudeCodeUserAgent(
            detectClaudeVersion: detectClaudeVersion,
            versionDetector: { ProviderVersionDetector.claudeVersion(environment: environment) })
        request.setValue(
            userAgent.replacingOccurrences(of: "claude-code/", with: "claude-cli/") + " (external, cli)",
            forHTTPHeaderField: "User-Agent")

        do {
            var response = try await transport.response(for: request)
            if response.statusCode == 400 || (response.statusCode == 403
                && !(String(data: response.data, encoding: .utf8)?.contains("user:profile") ?? false))
            {
                // Retry only the optional inventory rejection, keeping the same credential and version.
                try Task.checkCancellation()
                request.url = URL(string: self.baseURL + self.usagePath)
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                response = try await transport.response(for: request)
            }
            let data = response.data
            switch response.statusCode {
            case 200:
                let usage = try Self.decodeUsageResponse(data)
                ClaudeOAuthUsageRateLimitGate.recordSuccess(accessToken: accessToken)
                return usage
            case 401:
                throw ClaudeOAuthFetchError.unauthorized
            case 429:
                let retryAfter = Self.retryAfterDate(from: response.response)
                ClaudeOAuthUsageRateLimitGate.recordRateLimit(
                    accessToken: accessToken,
                    retryAfter: retryAfter)
                throw ClaudeOAuthFetchError.rateLimited(
                    retryAfter: ClaudeOAuthUsageRateLimitGate
                        .currentBlockedUntil(accessToken: accessToken) ?? retryAfter)
            default:
                let body = String(data: data, encoding: .utf8)
                throw ClaudeOAuthFetchError.serverError(response.statusCode, body)
            }
        } catch let error where ClaudeOAuthFetchError.isCancellation(error) {
            throw error
        } catch let error as ClaudeOAuthFetchError {
            throw error
        } catch {
            throw ClaudeOAuthFetchError.networkError(error)
        }
    }

    static func usageSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 90
        // Grant identifiers in the raw response must never enter the URL cache.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    static func fetchProfile(
        accessToken: String,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> OAuthProfileResponse
    {
        guard let url = URL(string: self.baseURL + self.profilePath) else {
            throw ClaudeOAuthFetchError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let response = try await transport.response(for: request)
            guard response.statusCode == 200 else {
                let body = String(data: response.data, encoding: .utf8)
                throw ClaudeOAuthFetchError.serverError(response.statusCode, body)
            }
            return try JSONDecoder().decode(OAuthProfileResponse.self, from: response.data)
        } catch let error as ClaudeOAuthFetchError {
            throw error
        } catch is DecodingError {
            throw ClaudeOAuthFetchError.invalidResponse
        } catch {
            throw ClaudeOAuthFetchError.networkError(error)
        }
    }

    static func decodeUsageResponse(_ data: Data) throws -> OAuthUsageResponse {
        let decoder = JSONDecoder()
        var usage = try decoder.decode(OAuthUsageResponse.self, from: data)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        usage.limits = json.map(ClaudeWebExtraRateWindowParser.scopedWeeklyLimits)
        return usage
    }

    private static func retryAfterDate(from response: HTTPURLResponse, now: Date = Date()) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }

        if let seconds = TimeInterval(raw), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: raw)
    }

    private static func claudeCodeUserAgent(
        detectClaudeVersion: Bool,
        versionDetector: () -> String? = { ProviderVersionDetector.claudeVersion() }) -> String
    {
        self.claudeCodeUserAgent(versionString: detectClaudeVersion ? versionDetector() : nil)
    }

    private static func claudeCodeUserAgent(versionString: String?) -> String {
        let version = self.normalizedClaudeCodeVersion(versionString) ?? self.fallbackClaudeCodeVersion
        return "claude-code/\(version)"
    }

    private static func normalizedClaudeCodeVersion(_ versionString: String?) -> String? {
        guard let raw = versionString?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let token = raw.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? raw
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct OAuthProfileResponse: Decodable, Sendable {
    let accountUuid: String?
    let emailAddress: String?
    let organizationUuid: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        let account = try Self.decodeNestedContainer(in: container, key: "account")
        let organization = try Self.decodeNestedContainer(in: container, key: "organization")
        self.accountUuid = account.flatMap { Self.decodeString(in: $0, keys: ["uuid"]) }
            ?? Self.decodeString(in: container, keys: ["accountUuid", "account_uuid"])
        self.emailAddress =
            account.flatMap { Self.decodeString(in: $0, keys: ["emailAddress", "email_address", "email"]) }
                ?? Self.decodeString(in: container, keys: ["emailAddress", "email_address", "email"])
        self.organizationUuid =
            organization.flatMap { Self.decodeString(in: $0, keys: ["uuid"]) }
                ?? Self.decodeString(in: container, keys: ["organizationUuid", "organization_uuid"])
    }

    init(emailAddress: String?, organizationUuid: String?, accountUuid: String? = nil) {
        self.accountUuid = accountUuid
        self.emailAddress = emailAddress
        self.organizationUuid = organizationUuid
    }

    private static func decodeString(
        in container: KeyedDecodingContainer<DynamicCodingKey>,
        keys: [String]) -> String?
    {
        for keyName in keys {
            guard let key = DynamicCodingKey(stringValue: keyName),
                  let value = try? container.decodeIfPresent(String.self, forKey: key)
            else {
                continue
            }
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty {
                return normalized
            }
        }
        return nil
    }

    private static func decodeNestedContainer(
        in container: KeyedDecodingContainer<DynamicCodingKey>,
        key keyName: String) throws -> KeyedDecodingContainer<DynamicCodingKey>?
    {
        guard let key = DynamicCodingKey(stringValue: keyName),
              container.contains(key),
              !((try? container.decodeNil(forKey: key)) ?? true)
        else {
            return nil
        }
        return try container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: key)
    }
}

struct OAuthUsageResponse: Decodable {
    let fiveHour: OAuthUsageWindow?
    let sevenDay: OAuthUsageWindow?
    let sevenDayOAuthApps: OAuthUsageWindow?
    let sevenDayOpus: OAuthUsageWindow?
    let sevenDaySonnet: OAuthUsageWindow?
    let sevenDayRoutines: OAuthUsageWindow?
    let sevenDayRoutinesSourceKey: String?
    let cloudCredits: ClaudeCloudCreditsSnapshot?
    let extraUsage: OAuthExtraUsage?
    let resetStatus: ClaudeLimitResetStatusResponse?
    /// Newer shape (superseding the flat `seven_day_*` fields above for scoped weekly
    /// windows): a flat list of limit entries, each optionally naming the model it scopes
    /// to via `scope.model.display_name` (e.g. "Fable" during a promotional access window).
    /// Filled by `ClaudeOAuthUsageFetcher.decodeUsageResponse` with the Web path's entry parser.
    fileprivate(set) var limits: [ClaudeScopedWeeklyLimitMapper.Limit]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.fiveHour = Self.decodeWindow(in: container, keys: ["five_hour"])
        self.sevenDay = Self.decodeWindow(in: container, keys: ["seven_day"])
        self.sevenDayOAuthApps = Self.decodeWindow(in: container, keys: ["seven_day_oauth_apps"])
        self.sevenDayOpus = Self.decodeWindow(in: container, keys: ["seven_day_opus"])
        self.sevenDaySonnet = Self.decodeWindow(in: container, keys: ["seven_day_sonnet"])
        let routines = Self.decodeWindowWithSource(in: container, keys: [
            "seven_day_routines",
            "seven_day_claude_routines",
            "claude_routines",
            "routines",
            "routine",
            "seven_day_cowork",
            "cowork",
        ])
        self.sevenDayRoutines = routines.window
        self.sevenDayRoutinesSourceKey = routines.sourceKey
        self.cloudCredits = Self.decodeValue(in: container, keys: ["iguana_necktie"])
        self.extraUsage = Self.decodeValue(in: container, keys: ["extra_usage"])
        self.resetStatus = Self.decodeValue(in: container, keys: ["cedar_ember"])
    }

    private static func decodeWindow(
        in container: KeyedDecodingContainer<DynamicCodingKey>,
        keys: [String]) -> OAuthUsageWindow?
    {
        self.decodeValue(in: container, keys: keys)
    }

    private static func decodeWindowWithSource(
        in container: KeyedDecodingContainer<DynamicCodingKey>,
        keys: [String]) -> (window: OAuthUsageWindow?, sourceKey: String?)
    {
        for keyName in keys {
            guard let key = DynamicCodingKey(stringValue: keyName) else { continue }
            guard container.contains(key) else { continue }
            if let value = try? container.decodeIfPresent(OAuthUsageWindow.self, forKey: key) {
                return (value, keyName)
            }
        }
        return (nil, nil)
    }

    private static func decodeValue<T: Decodable>(
        in container: KeyedDecodingContainer<DynamicCodingKey>,
        keys: [String]) -> T?
    {
        for keyName in keys {
            guard let key = DynamicCodingKey(stringValue: keyName) else { continue }
            if let value = try? container.decodeIfPresent(T.self, forKey: key) {
                return value
            }
        }
        return nil
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        nil
    }
}

struct OAuthUsageWindow: Decodable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct OAuthExtraUsage: Decodable {
    let isEnabled: Bool?
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?
    let currency: String?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
        case currency
    }
}

#if DEBUG
extension ClaudeOAuthUsageFetcher {
    static func _decodeUsageResponseForTesting(_ data: Data) throws -> OAuthUsageResponse {
        try self.decodeUsageResponse(data)
    }

    static func _userAgentForTesting(versionString: String?) -> String {
        self.claudeCodeUserAgent(versionString: versionString)
    }

    static func _userAgentForTesting(
        detectClaudeVersion: Bool,
        versionDetector: () -> String?) -> String
    {
        self.claudeCodeUserAgent(
            detectClaudeVersion: detectClaudeVersion,
            versionDetector: versionDetector)
    }

    static func _retryAfterDateForTesting(from response: HTTPURLResponse, now: Date) -> Date? {
        self.retryAfterDate(from: response, now: now)
    }
}
#endif
