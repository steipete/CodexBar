import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CodexUsageResponse: Decodable, Sendable {
    public let planType: PlanType?
    public let rateLimit: RateLimitDetails?
    public let credits: CreditDetails?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
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

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
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

    public static func fetchUsage(accessToken: String, accountId: String?) async throws -> CodexUsageResponse {
        var request = URLRequest(url: Self.resolveUsageURL())
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CodexOAuthFetchError.invalidResponse
            }

            switch http.statusCode {
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
                throw CodexOAuthFetchError.serverError(http.statusCode, body)
            }
        } catch let error as CodexOAuthFetchError {
            throw error
        } catch {
            throw CodexOAuthFetchError.networkError(error)
        }
    }

    private static func resolveUsageURL() -> URL {
        self.resolveUsageURL(env: ProcessInfo.processInfo.environment, configContents: nil)
    }

    private static func resolveUsageURL(env: [String: String], configContents: String?) -> URL {
        let baseURL = self.resolveChatGPTBaseURL(env: env, configContents: configContents)
        let normalized = self.normalizeChatGPTBaseURL(baseURL)
        let path = normalized.contains("/backend-api") ? Self.chatGPTUsagePath : Self.codexUsagePath
        let full = normalized + path
        return URL(string: full) ?? URL(string: Self.defaultChatGPTBaseURL + Self.chatGPTUsagePath)!
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
}

#if DEBUG
extension CodexOAuthUsageFetcher {
    static func _resolveUsageURLForTesting(env: [String: String] = [:], configContents: String? = nil) -> URL {
        self.resolveUsageURL(env: env, configContents: configContents)
    }

    static func _decodeUsageResponseForTesting(_ data: Data) throws -> CodexUsageResponse {
        try JSONDecoder().decode(CodexUsageResponse.self, from: data)
    }
}
#endif
