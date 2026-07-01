import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CodexUsageResponse: Decodable, Sendable {
    public let planType: PlanType?
    public let rateLimit: RateLimitDetails?
    public let credits: CreditDetails?
    public let individualLimit: SpendControlLimitSnapshot?
    /// Model-specific limits (e.g. GPT-5.3-Codex-Spark) that sit alongside the primary/weekly windows.
    public let additionalRateLimits: [AdditionalRateLimit]?
    let additionalRateLimitsDecodeFailed: Bool

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
        case individualLimit = "individual_limit"
        case individualLimitCamel = "individualLimit"
        case additionalRateLimits = "additional_rate_limits"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.planType = try? container.decodeIfPresent(PlanType.self, forKey: .planType)
        self.rateLimit = try? container.decodeIfPresent(RateLimitDetails.self, forKey: .rateLimit)
        self.credits = try? container.decodeIfPresent(CreditDetails.self, forKey: .credits)
        self.individualLimit = (try? container.decodeIfPresent(
            SpendControlLimitSnapshot.self,
            forKey: .individualLimit))
            ?? (try? container.decodeIfPresent(SpendControlLimitSnapshot.self, forKey: .individualLimitCamel))
        // Optional and additive: missing/malformed extra limits must never disturb primary/weekly mapping.
        // Decode per element so a single malformed entry cannot discard its valid siblings; a non-array
        // value (or absent field) leaves `additionalRateLimits` nil and primary/weekly mapping untouched.
        let additionalRateLimitsHadValue = Self.hasNonNilValue(container: container, key: .additionalRateLimits)
        do {
            let decoded = try container.decodeIfPresent(
                [LossyAdditionalRateLimit].self,
                forKey: .additionalRateLimits)
            self.additionalRateLimits = decoded?.compactMap(\.value)
            self.additionalRateLimitsDecodeFailed = decoded?.contains(where: \.decodeFailed) == true
                || self.additionalRateLimits?.contains(where: \.hasWindowDecodeFailure) == true
        } catch {
            self.additionalRateLimits = nil
            self.additionalRateLimitsDecodeFailed = additionalRateLimitsHadValue
        }
    }

    private static func hasNonNilValue(
        container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys) -> Bool
    {
        guard container.contains(key) else { return false }
        return (try? container.decodeNil(forKey: key)) == false
    }

    public enum PlanType: Sendable, Decodable, Equatable {
        case guest
        case free
        case go
        case plus
        case pro
        case freeWorkspace
        case team
        case business
        case education
        case quorum
        case k12
        case enterprise
        case edu
        case unknown(String)

        public var rawValue: String {
            switch self {
            case .guest: "guest"
            case .free: "free"
            case .go: "go"
            case .plus: "plus"
            case .pro: "pro"
            case .freeWorkspace: "free_workspace"
            case .team: "team"
            case .business: "business"
            case .education: "education"
            case .quorum: "quorum"
            case .k12: "k12"
            case .enterprise: "enterprise"
            case .edu: "edu"
            case let .unknown(value): value
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            switch value {
            case "guest": self = .guest
            case "free": self = .free
            case "go": self = .go
            case "plus": self = .plus
            case "pro": self = .pro
            case "free_workspace": self = .freeWorkspace
            case "team": self = .team
            case "business": self = .business
            case "education": self = .education
            case "quorum": self = .quorum
            case "k12": self = .k12
            case "enterprise": self = .enterprise
            case "edu": self = .edu
            default:
                self = .unknown(value)
            }
        }
    }

    public struct RateLimitDetails: Decodable, Sendable {
        public let primaryWindow: WindowSnapshot?
        public let secondaryWindow: WindowSnapshot?
        public let individualLimit: SpendControlLimitSnapshot?
        let primaryWindowDecodeFailed: Bool
        let secondaryWindowDecodeFailed: Bool

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
            case individualLimit = "individual_limit"
            case individualLimitCamel = "individualLimit"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let primaryHadValue = Self.hasNonNilValue(container: container, key: .primaryWindow)
            do {
                self.primaryWindow = try container.decodeIfPresent(WindowSnapshot.self, forKey: .primaryWindow)
                self.primaryWindowDecodeFailed = false
            } catch {
                self.primaryWindow = nil
                self.primaryWindowDecodeFailed = primaryHadValue
            }

            let secondaryHadValue = Self.hasNonNilValue(container: container, key: .secondaryWindow)
            do {
                self.secondaryWindow = try container.decodeIfPresent(WindowSnapshot.self, forKey: .secondaryWindow)
                self.secondaryWindowDecodeFailed = false
            } catch {
                self.secondaryWindow = nil
                self.secondaryWindowDecodeFailed = secondaryHadValue
            }
            self.individualLimit = (try? container.decodeIfPresent(
                SpendControlLimitSnapshot.self,
                forKey: .individualLimit))
                ?? (try? container.decodeIfPresent(SpendControlLimitSnapshot.self, forKey: .individualLimitCamel))
        }

        private static func hasNonNilValue(
            container: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys) -> Bool
        {
            guard container.contains(key) else { return false }
            return (try? container.decodeNil(forKey: key)) == false
        }

        var hasWindowDecodeFailure: Bool {
            self.primaryWindowDecodeFailed || self.secondaryWindowDecodeFailed
        }
    }

    public struct WindowSnapshot: Decodable, Sendable {
        public let usedPercent: Int
        public let resetAt: Int
        public let limitWindowSeconds: Int

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }
    }

    /// One entry of `additional_rate_limits`: a named, model-specific limit (e.g. GPT-5.3-Codex-Spark)
    /// whose windows reuse the same shape as the primary/weekly `RateLimitDetails`.
    public struct AdditionalRateLimit: Decodable, Sendable {
        public let limitName: String?
        public let meteredFeature: String?
        public let rateLimit: RateLimitDetails?
        let rateLimitDecodeFailed: Bool

        enum CodingKeys: String, CodingKey {
            case limitName = "limit_name"
            case meteredFeature = "metered_feature"
            case rateLimit = "rate_limit"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.limitName = try? container.decodeIfPresent(String.self, forKey: .limitName)
            self.meteredFeature = try? container.decodeIfPresent(String.self, forKey: .meteredFeature)
            let rateLimitHadValue = Self.hasNonNilValue(container: container, key: .rateLimit)
            do {
                self.rateLimit = try container.decodeIfPresent(RateLimitDetails.self, forKey: .rateLimit)
                self.rateLimitDecodeFailed = false
            } catch {
                self.rateLimit = nil
                self.rateLimitDecodeFailed = rateLimitHadValue
            }
        }

        private static func hasNonNilValue(
            container: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys) -> Bool
        {
            guard container.contains(key) else { return false }
            return (try? container.decodeNil(forKey: key)) == false
        }

        var hasWindowDecodeFailure: Bool {
            self.rateLimitDecodeFailed || self.rateLimit?.hasWindowDecodeFailure == true
        }
    }

    /// Decodes a single `additional_rate_limits` element without ever throwing, so one malformed
    /// entry cannot discard its valid siblings during array decoding.
    private struct LossyAdditionalRateLimit: Decodable {
        let value: AdditionalRateLimit?
        let decodeFailed: Bool

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.value = try? container.decode(AdditionalRateLimit.self)
            self.decodeFailed = self.value == nil
        }
    }

    public struct SpendControlLimitSnapshot: Decodable, Sendable {
        public let limit: Double?
        public let used: Double?
        public let remainingPercent: Double?
        public let resetsAt: Int?

        enum CodingKeys: String, CodingKey {
            case limit
            case used
            case remainingPercent
            case remainingPercentSnake = "remaining_percent"
            case resetsAt
            case resetsAtSnake = "resets_at"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.limit = Self.decodeFlexibleDouble(container, forKey: .limit)
            self.used = Self.decodeFlexibleDouble(container, forKey: .used)
            self.remainingPercent = Self.decodeFlexibleDouble(container, forKey: .remainingPercent)
                ?? Self.decodeFlexibleDouble(container, forKey: .remainingPercentSnake)
            self.resetsAt = Self.decodeFlexibleInt(container, forKey: .resetsAt)
                ?? Self.decodeFlexibleInt(container, forKey: .resetsAtSnake)
        }

        private static func decodeFlexibleDouble(
            _ container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys) -> Double?
        {
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return Double(value)
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }

        private static func decodeFlexibleInt(
            _ container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys) -> Int?
        {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return Int(value)
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }
    }

    public struct CreditDetails: Decodable, Sendable {
        public let hasCredits: Bool
        public let unlimited: Bool
        public let balance: Double?

        enum CodingKeys: String, CodingKey {
            case hasCredits = "has_credits"
            case unlimited
            case balance
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.hasCredits = (try? container.decode(Bool.self, forKey: .hasCredits)) ?? false
            self.unlimited = (try? container.decode(Bool.self, forKey: .unlimited)) ?? false
            if let balance = try? container.decode(Double.self, forKey: .balance) {
                self.balance = balance
            } else if let balance = try? container.decode(String.self, forKey: .balance),
                      let value = Double(balance)
            {
                self.balance = value
            } else {
                self.balance = nil
            }
        }
    }
}

public enum CodexOAuthFetchError: LocalizedError, Sendable {
    case unauthorized
    case invalidResponse
    case serverError(Int, String?)
    case networkError(Error)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Codex OAuth token expired or invalid. Run `codex` to re-authenticate."
        case .invalidResponse:
            return "Invalid response from Codex usage API."
        case let .serverError(code, message):
            if let message, !message.isEmpty {
                return "Codex API error \(code): \(message)"
            }
            return "Codex API error \(code)."
        case let .networkError(error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}

public enum CodexOAuthUsageFetcher {
    private static let defaultChatGPTBaseURL = "https://chatgpt.com/backend-api/"
    private static let chatGPTUsagePath = "/wham/usage"
    private static let codexUsagePath = "/api/codex/usage"
    private static let rateLimitResetCreditsPath = "/wham/rate-limit-reset-credits"

    public static func fetchUsage(
        accessToken: String,
        accountId: String?,
        env: [String: String] = ProcessInfo.processInfo.environment) async throws -> CodexUsageResponse
    {
        var request = URLRequest(url: Self.resolveUsageURL(env: env))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let response = try await ProviderHTTPClient.shared.response(for: request)
            let data = response.data

            switch response.statusCode {
            case 200...299:
                do {
                    return try JSONDecoder().decode(CodexUsageResponse.self, from: data)
                } catch {
                    throw CodexOAuthFetchError.invalidResponse
                }
            case 401, 403:
                throw CodexOAuthFetchError.unauthorized
            default:
                let body = String(data: data, encoding: .utf8)
                throw CodexOAuthFetchError.serverError(response.statusCode, body)
            }
        } catch let error as CodexOAuthFetchError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw CodexOAuthFetchError.networkError(error)
        }
    }

    public static func fetchRateLimitResetCredits(
        accessToken: String,
        accountId: String?,
        env: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 4,
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws
        -> CodexRateLimitResetCreditsSnapshot
    {
        var request = URLRequest(url: Self.resolveRateLimitResetCreditsURL(env: env), timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")

        if let accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-ID")
        }

        do {
            let response = try await transport.response(for: request)
            let data = response.data

            switch response.statusCode {
            case 200...299:
                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .custom(Self.decodeISO8601Date)
                    let payload = try decoder.decode(RateLimitResetCreditsResponse.self, from: data)
                    guard payload.availableCount >= 0 else {
                        throw CodexOAuthFetchError.invalidResponse
                    }
                    return CodexRateLimitResetCreditsSnapshot(
                        credits: payload.credits.map(\.model),
                        availableCount: payload.availableCount,
                        updatedAt: Date())
                } catch {
                    throw CodexOAuthFetchError.invalidResponse
                }
            case 401, 403:
                throw CodexOAuthFetchError.unauthorized
            default:
                let body = String(data: data, encoding: .utf8)
                throw CodexOAuthFetchError.serverError(response.statusCode, body)
            }
        } catch let error as CodexOAuthFetchError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw CodexOAuthFetchError.networkError(error)
        }
    }

    private static func resolveUsageURL(env: [String: String]) -> URL {
        self.resolveUsageURL(env: env, configContents: nil)
    }

    private static func resolveUsageURL(env: [String: String], configContents: String?) -> URL {
        let baseURL = self.resolveChatGPTBaseURL(env: env, configContents: configContents)
        let normalized = self.normalizeChatGPTBaseURL(baseURL)
        let path = normalized.contains("/backend-api") ? Self.chatGPTUsagePath : Self.codexUsagePath
        let full = normalized + path
        return URL(string: full) ?? URL(string: Self.defaultChatGPTBaseURL + Self.chatGPTUsagePath)!
    }

    private static func resolveRateLimitResetCreditsURL(env: [String: String]) -> URL {
        self.resolveRateLimitResetCreditsURL(env: env, configContents: nil)
    }

    private static func resolveRateLimitResetCreditsURL(env: [String: String], configContents: String?) -> URL {
        let baseURL = self.resolveChatGPTBaseURL(env: env, configContents: configContents)
        let normalized = self.normalizeChatGPTBaseURL(baseURL)
        let full = normalized + Self.rateLimitResetCreditsPath
        return URL(string: full) ?? URL(string: Self.defaultChatGPTBaseURL + Self.rateLimitResetCreditsPath)!
    }

    private static func resolveChatGPTBaseURL(env: [String: String], configContents: String?) -> String {
        if let configContents, let parsed = self.parseChatGPTBaseURL(from: configContents) {
            return parsed
        }
        if let contents = self.loadConfigContents(env: env),
           let parsed = self.parseChatGPTBaseURL(from: contents)
        {
            return parsed
        }
        return Self.defaultChatGPTBaseURL
    }

    private static func normalizeChatGPTBaseURL(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { trimmed = Self.defaultChatGPTBaseURL }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if trimmed.hasPrefix("https://chatgpt.com") || trimmed.hasPrefix("https://chat.openai.com"),
           !trimmed.contains("/backend-api")
        {
            trimmed += "/backend-api"
        }
        return trimmed
    }

    private static func parseChatGPTBaseURL(from contents: String) -> String? {
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true).first
            let trimmed = line?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == "chatgpt_base_url" else { continue }
            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("'"), value.hasSuffix("'") {
                value = String(value.dropFirst().dropLast())
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func loadConfigContents(env: [String: String]) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = env["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = (codexHome?.isEmpty == false) ? URL(fileURLWithPath: codexHome!) : home
            .appendingPathComponent(".codex")
        let url = root.appendingPathComponent("config.toml")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private struct RateLimitResetCreditsResponse: Decodable {
        let credits: [RateLimitResetCreditResponse]
        let availableCount: Int

        private enum CodingKeys: String, CodingKey {
            case credits
            case availableCount = "available_count"
        }
    }

    private struct RateLimitResetCreditResponse: Decodable {
        let id: String
        let resetType: String
        let status: CodexRateLimitResetCreditStatus
        let grantedAt: Date
        let expiresAt: Date?
        let redeemStartedAt: Date?
        let redeemedAt: Date?
        let title: String?
        let description: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case resetType = "reset_type"
            case status
            case grantedAt = "granted_at"
            case expiresAt = "expires_at"
            case redeemStartedAt = "redeem_started_at"
            case redeemedAt = "redeemed_at"
            case title
            case description
        }

        var model: CodexRateLimitResetCredit {
            CodexRateLimitResetCredit(
                id: self.id,
                resetType: self.resetType,
                status: self.status,
                grantedAt: self.grantedAt,
                expiresAt: self.expiresAt,
                redeemStartedAt: self.redeemStartedAt,
                redeemedAt: self.redeemedAt,
                title: self.title,
                description: self.description)
        }
    }

    private static func decodeISO8601Date(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let seconds = ISO8601DateFormatter()
        seconds.formatOptions = [.withInternetDateTime]
        if let date = fractional.date(from: raw) ?? seconds.date(from: raw) {
            return date
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Invalid ISO-8601 date: \(raw)")
    }
}

#if DEBUG
extension CodexOAuthUsageFetcher {
    static func _resolveUsageURLForTesting(env: [String: String] = [:], configContents: String? = nil) -> URL {
        self.resolveUsageURL(env: env, configContents: configContents)
    }

    static func _decodeUsageResponseForTesting(_ data: Data) throws -> CodexUsageResponse {
        try JSONDecoder().decode(CodexUsageResponse.self, from: data)
    }

    static func _resolveRateLimitResetCreditsURLForTesting(
        env: [String: String] = [:],
        configContents: String? = nil) -> URL
    {
        self.resolveRateLimitResetCreditsURL(env: env, configContents: configContents)
    }

    static func _decodeRateLimitResetCreditsForTesting(
        _ data: Data,
        now: Date = Date()) throws -> CodexRateLimitResetCreditsSnapshot
    {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Self.decodeISO8601Date)
        let payload = try decoder.decode(RateLimitResetCreditsResponse.self, from: data)
        return CodexRateLimitResetCreditsSnapshot(
            credits: payload.credits.map(\.model),
            availableCount: payload.availableCount,
            updatedAt: now)
    }
}
#endif
