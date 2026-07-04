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

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Claude OAuth request unauthorized. Run `claude` to re-authenticate."
        case .rateLimited:
            return "Claude OAuth usage endpoint is rate limited by Anthropic right now. Wait a few minutes, "
                + "then click Refresh. If it keeps happening, run `claude logout && claude login`, then try again."
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
    private static let usagePath = "/api/oauth/usage"
    private static let betaHeader = "oauth-2025-04-20"
    private static let fallbackClaudeCodeVersion = "2.1.0"

    static func fetchUsage(
        accessToken: String,
        detectClaudeVersion: Bool = true) async throws -> OAuthUsageResponse
    {
        if let blockedUntil = ClaudeOAuthUsageRateLimitGate.blockedUntil() {
            throw ClaudeOAuthFetchError.rateLimited(retryAfter: blockedUntil)
        }

        guard let url = URL(string: baseURL + usagePath) else {
            throw ClaudeOAuthFetchError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // OAuth usage endpoint currently requires the beta header.
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(
            Self.claudeCodeUserAgent(detectClaudeVersion: detectClaudeVersion),
            forHTTPHeaderField: "User-Agent")

        do {
            let response = try await ProviderHTTPClient.shared.response(for: request)
            let data = response.data
            switch response.statusCode {
            case 200:
                let usage = try Self.decodeUsageResponse(data)
                ClaudeOAuthUsageRateLimitGate.recordSuccess()
                return usage
            case 401:
                throw ClaudeOAuthFetchError.unauthorized
            case 429:
                let retryAfter = Self.retryAfterDate(from: response.response)
                ClaudeOAuthUsageRateLimitGate.recordRateLimit(retryAfter: retryAfter)
                throw ClaudeOAuthFetchError.rateLimited(
                    retryAfter: ClaudeOAuthUsageRateLimitGate.currentBlockedUntil() ?? retryAfter)
            case 403:
                let body = String(data: data, encoding: .utf8)
                throw ClaudeOAuthFetchError.serverError(response.statusCode, body)
            default:
                let body = String(data: data, encoding: .utf8)
                throw ClaudeOAuthFetchError.serverError(response.statusCode, body)
            }
        } catch let error as ClaudeOAuthFetchError {
            throw error
        } catch {
            throw ClaudeOAuthFetchError.networkError(error)
        }
    }

    static func decodeUsageResponse(_ data: Data) throws -> OAuthUsageResponse {
        let decoder = JSONDecoder()
        return try decoder.decode(OAuthUsageResponse.self, from: data)
    }

    static func parseISO8601Date(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
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

struct OAuthUsageResponse: Decodable {
    let fiveHour: OAuthUsageWindow?
    let sevenDay: OAuthUsageWindow?
    let sevenDayOAuthApps: OAuthUsageWindow?
    let sevenDayOpus: OAuthUsageWindow?
    let sevenDaySonnet: OAuthUsageWindow?
    let sevenDayRoutines: OAuthUsageWindow?
    let sevenDayRoutinesSourceKey: String?
    let iguanaNecktie: OAuthUsageWindow?
    let extraUsage: OAuthExtraUsage?
    /// Newer shape (superseding the flat `seven_day_*` fields above for scoped weekly
    /// windows): a flat list of limit entries, each optionally naming the model it scopes
    /// to via `scope.model.display_name` (e.g. "Fable" during a promotional access window).
    let limits: [OAuthLimitEntry]?

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
        self.iguanaNecktie = Self.decodeWindow(in: container, keys: ["iguana_necktie"])
        self.extraUsage = Self.decodeValue(in: container, keys: ["extra_usage"])
        self.limits = Self.decodeValue(in: container, keys: ["limits"])
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
        var firstNullKey: String?
        for keyName in keys {
            guard let key = DynamicCodingKey(stringValue: keyName) else { continue }
            guard container.contains(key) else { continue }
            if let value = try? container.decodeIfPresent(OAuthUsageWindow.self, forKey: key) {
                return (value, keyName)
            }
            if firstNullKey == nil {
                firstNullKey = keyName
            }
        }
        return (nil, firstNullKey)
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

/// A single entry from the `limits` array. `kind`/`group` classify the limit
/// (e.g. `kind: "weekly_scoped"`, `group: "weekly"`); `scope.model.display_name` names the
/// model it applies to when the limit is scoped to one, rather than the whole account.
struct OAuthLimitEntry: Decodable {
    let kind: String?
    let group: String?
    let percent: Double?
    let resetsAt: String?
    let scope: OAuthLimitScope?
    let isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case kind
        case group
        case percent
        case resetsAt = "resets_at"
        case scope
        case isActive = "is_active"
    }
}

struct OAuthLimitScope: Decodable {
    let model: OAuthLimitScopeModel?
}

struct OAuthLimitScopeModel: Decodable {
    let id: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
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
