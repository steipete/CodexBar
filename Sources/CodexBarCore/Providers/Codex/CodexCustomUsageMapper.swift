import Foundation

/// Errors surfaced by the Codex custom-provider usage mapper.
public enum CodexCustomUsageError: LocalizedError, Sendable {
    case missingCredentials
    case invalidResponse
    case parseFailed(String)
    case apiError(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Custom API source unavailable: resolve OPENAI_API_KEY in ~/.codex/auth.json and base_url in config.toml."
        case .invalidResponse:
            "Custom provider usage endpoint reported the response is not valid."
        case let .parseFailed(message):
            "Custom provider usage parse error: \(message)"
        case let .apiError(message):
            "Custom provider usage error: \(message)"
        }
    }
}

/// A mapped Codex custom-provider `/v1/usage` response, split into the two
/// payloads CodexBar's two independent pipelines consume.
public struct CodexCustomUsageSnapshot: Sendable {
    public let credits: CreditsSnapshot
    public let usage: UsageSnapshot

    public init(credits: CreditsSnapshot, usage: UsageSnapshot) {
        self.credits = credits
        self.usage = usage
    }
}

/// Fixed mapper for a custom-provider-style `GET /v1/usage` response into CodexBar's
/// existing display models. No user-configurable extractor.
///
/// - `remaining` (+ `unit`) → `CreditsSnapshot.remaining`.
/// - `subscription.daily_limit_usd` / `daily_usage_usd` → `CreditsSnapshot.codexCreditLimit`
///   titled "Daily limit".
/// - `subscription.weekly_limit_usd` > 0 → a weekly `NamedRateWindow` in
///   `usage.extraRateWindows`. When the weekly limit is 0/absent, no window.
/// - No `primary`/`secondary` rate window is produced, so the menu bar stays on
///   the daily-remaining balance.
public struct CodexCustomUsageMapper: Sendable {
    public static let weeklyWindowID = "codex-custom-weekly"
    public static let weeklyWindowTitle = "Weekly limit"
    public static let weeklyWindowMinutes = 10080

    public init() {}

    public static func map(
        data: Data,
        accountEmail: String? = nil,
        updatedAt: Date = Date()) throws -> CodexCustomUsageSnapshot
    {
        let response = try Self.decode(data: data)
        if response.isValid == false {
            throw CodexCustomUsageError.invalidResponse
        }
        return Self.map(response: response, accountEmail: accountEmail, updatedAt: updatedAt)
    }

    /// Parses the response into the typed `Decodable` shape. Exposed for tests.
    static func decode(data: Data) throws -> CodexCustomUsageResponse {
        do {
            return try JSONDecoder().decode(CodexCustomUsageResponse.self, from: data)
        } catch let error as CodexCustomUsageError {
            throw error
        } catch {
            throw CodexCustomUsageError.parseFailed(error.localizedDescription)
        }
    }

    static func map(
        response: CodexCustomUsageResponse,
        accountEmail: String?,
        updatedAt: Date) -> CodexCustomUsageSnapshot
    {
        let subscription = response.subscription
        let dailyLimit = subscription?.dailyLimitUSD
        let dailyUsage = subscription?.dailyUsageUSD ?? 0
        let remaining = response.remaining ?? 0

        let creditLimit = dailyLimit.map { limit -> CodexCreditLimitSnapshot in
            let usedPercent = limit > 0
                ? min(100, max(0, 100 * dailyUsage / limit))
                : 100
            let remainingPercent = max(0, 100 - usedPercent)
            return CodexCreditLimitSnapshot(
                title: "Daily limit",
                used: dailyUsage,
                limit: limit,
                remainingPercent: remainingPercent,
                resetsAt: subscription?.expiresAt,
                updatedAt: updatedAt)
        }

        let credits = CreditsSnapshot(
            remaining: remaining,
            events: [],
            updatedAt: updatedAt,
            codexCreditLimit: creditLimit)

        let weeklyWindow = Self.weeklyWindow(
            limit: subscription?.weeklyLimitUSD,
            usage: subscription?.weeklyUsageUSD ?? 0)
        let extraRateWindows = weeklyWindow.map { [$0] }

        let usage = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: extraRateWindows,
            updatedAt: updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: accountEmail,
                accountOrganization: response.planName,
                loginMethod: "custom-api"))
        return CodexCustomUsageSnapshot(credits: credits, usage: usage)
    }

    static func weeklyWindow(limit: Double?, usage: Double) -> NamedRateWindow? {
        guard let limit, limit > 0 else { return nil }
        let usedPercent = min(100, max(0, 100 * usage / limit))
        return NamedRateWindow(
            id: Self.weeklyWindowID,
            title: Self.weeklyWindowTitle,
            window: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: Self.weeklyWindowMinutes,
                resetsAt: nil,
                resetDescription: nil))
    }
}
