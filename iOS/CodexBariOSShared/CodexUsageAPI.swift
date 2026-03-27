import Foundation

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

        public init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
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

public enum CodexUsageAPIError: LocalizedError, Sendable {
    case unauthorized
    case invalidResponse
    case serverError(Int, String?)
    case networkError(Error)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Codex access token is invalid or expired."
        case .invalidResponse:
            return "Codex usage API returned an invalid response."
        case let .serverError(code, message):
            if let message, !message.isEmpty {
                return "Codex usage API error \(code): \(message)"
            }
            return "Codex usage API error \(code)."
        case let .networkError(error):
            return "Codex network error: \(error.localizedDescription)"
        }
    }
}

public enum CodexUsageAPI {
    private static let defaultURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public static func fetchUsage(accessToken: String, accountID: String?) async throws -> CodexUsageResponse {
        var request = URLRequest(url: Self.defaultURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("CodexBar iOS", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CodexUsageAPIError.invalidResponse
            }
            switch http.statusCode {
            case 200 ... 299:
                do {
                    return try JSONDecoder().decode(CodexUsageResponse.self, from: data)
                } catch {
                    throw CodexUsageAPIError.invalidResponse
                }
            case 401, 403:
                throw CodexUsageAPIError.unauthorized
            default:
                throw CodexUsageAPIError.serverError(http.statusCode, String(data: data, encoding: .utf8))
            }
        } catch let error as CodexUsageAPIError {
            throw error
        } catch {
            throw CodexUsageAPIError.networkError(error)
        }
    }

    public static func makeEntry(
        response: CodexUsageResponse,
        updatedAt: Date = Date()) -> WidgetSnapshot.ProviderEntry
    {
        WidgetSnapshot.ProviderEntry(
            provider: .codex,
            updatedAt: updatedAt,
            primary: self.makeWindow(response.rateLimit?.primaryWindow),
            secondary: self.makeWindow(response.rateLimit?.secondaryWindow),
            tertiary: nil,
            creditsRemaining: response.credits?.balance,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
    }

    private static func makeWindow(_ window: CodexUsageResponse.WindowSnapshot?) -> RateWindow? {
        guard let window else { return nil }
        let resetDate = Date(timeIntervalSince1970: TimeInterval(window.resetAt))
        return RateWindow(
            usedPercent: Double(window.usedPercent),
            windowMinutes: window.limitWindowSeconds / 60,
            resetsAt: resetDate,
            resetDescription: DisplayFormat.resetDescription(from: resetDate))
    }
}
