import Foundation

public struct ClaudeOAuthUsageResponse: Decodable, Sendable {
    public let fiveHour: UsageWindow?
    public let sevenDay: UsageWindow?
    public let sevenDayOAuthApps: UsageWindow?
    public let sevenDayOpus: UsageWindow?
    public let sevenDaySonnet: UsageWindow?
    public let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOAuthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
    }

    public struct UsageWindow: Decodable, Sendable {
        public let utilization: Double?
        public let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    public struct ExtraUsage: Decodable, Sendable {
        public let isEnabled: Bool?
        public let monthlyLimit: Double?
        public let usedCredits: Double?
        public let utilization: Double?
        public let currency: String?

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case monthlyLimit = "monthly_limit"
            case usedCredits = "used_credits"
            case utilization
            case currency
        }
    }
}

public enum ClaudeUsageAPIError: LocalizedError, Sendable {
    case unauthorized
    case invalidResponse
    case serverError(Int, String?)
    case networkError(Error)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Claude access token is invalid or expired."
        case .invalidResponse:
            return "Claude usage API returned an invalid response."
        case let .serverError(code, body):
            if let body, !body.isEmpty {
                return "Claude usage API error \(code): \(body)"
            }
            return "Claude usage API error \(code)."
        case let .networkError(error):
            return "Claude network error: \(error.localizedDescription)"
        }
    }
}

public enum ClaudeUsageAPI {
    private static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let betaHeader = "oauth-2025-04-20"

    public static func fetchUsage(accessToken: String) async throws -> ClaudeOAuthUsageResponse {
        var request = URLRequest(url: Self.url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ClaudeUsageAPIError.invalidResponse
            }
            switch http.statusCode {
            case 200:
                do {
                    return try JSONDecoder().decode(ClaudeOAuthUsageResponse.self, from: data)
                } catch {
                    throw ClaudeUsageAPIError.invalidResponse
                }
            case 401:
                throw ClaudeUsageAPIError.unauthorized
            default:
                throw ClaudeUsageAPIError.serverError(http.statusCode, String(data: data, encoding: .utf8))
            }
        } catch let error as ClaudeUsageAPIError {
            throw error
        } catch {
            throw ClaudeUsageAPIError.networkError(error)
        }
    }

    public static func makeEntry(
        response: ClaudeOAuthUsageResponse,
        updatedAt: Date = Date()) throws -> WidgetSnapshot.ProviderEntry
    {
        guard let primary = self.makeWindow(response.fiveHour, windowMinutes: 5 * 60) else {
            throw ClaudeUsageAPIError.invalidResponse
        }

        return WidgetSnapshot.ProviderEntry(
            provider: .claude,
            updatedAt: updatedAt,
            primary: primary,
            secondary: self.makeWindow(response.sevenDay, windowMinutes: 7 * 24 * 60),
            tertiary: self.makeWindow(response.sevenDaySonnet ?? response.sevenDayOpus, windowMinutes: 7 * 24 * 60),
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
    }

    private static func makeWindow(
        _ window: ClaudeOAuthUsageResponse.UsageWindow?,
        windowMinutes: Int) -> RateWindow?
    {
        guard let window,
              let utilization = window.utilization
        else { return nil }
        let resetDate = self.parseISO8601Date(window.resetsAt)
        return RateWindow(
            usedPercent: utilization,
            windowMinutes: windowMinutes,
            resetsAt: resetDate,
            resetDescription: resetDate.map { DisplayFormat.resetDescription(from: $0) })
    }

    private static func parseISO8601Date(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
