import Foundation

public enum ClaudePlan: String, CaseIterable, Sendable {
    case max
    case pro
    case team
    case enterprise
    case ultra

    public var brandedLoginMethod: String {
        switch self {
        case .max:
            "Claude Max"
        case .pro:
            "Claude Pro"
        case .team:
            "Claude Team"
        case .enterprise:
            "Claude Enterprise"
        case .ultra:
            "Claude Ultra"
        }
    }

    /// Branded label including the Max usage multiplier when the rate-limit tier
    /// carries one, e.g. "Claude Max 5x" / "Claude Max 20x". Falls back to the plain
    /// branded label for tiers without a multiplier (Pro/Team/Enterprise, or a bare Max).
    public func brandedLoginMethod(rateLimitTier: String?) -> String {
        guard let multiplier = Self.usageMultiplier(for: self, rateLimitTier: rateLimitTier) else {
            return self.brandedLoginMethod
        }
        return "\(self.brandedLoginMethod) \(multiplier)"
    }

    public var compactLoginMethod: String {
        switch self {
        case .max:
            "Max"
        case .pro:
            "Pro"
        case .team:
            "Team"
        case .enterprise:
            "Enterprise"
        case .ultra:
            "Ultra"
        }
    }

    public var countsAsSubscription: Bool {
        switch self {
        case .max, .pro, .team, .ultra:
            true
        case .enterprise:
            false
        }
    }

    public static func fromOAuthRateLimitTier(_ rateLimitTier: String?) -> Self? {
        self.fromRateLimitTier(rateLimitTier)
    }

    public static func fromOAuthCredentials(subscriptionType: String?, rateLimitTier: String?) -> Self? {
        self.fromCompatibilityLoginMethod(subscriptionType)
            ?? self.fromOAuthRateLimitTier(rateLimitTier)
    }

    public static func fromWebAccount(rateLimitTier: String?, billingType: String?) -> Self? {
        if let plan = self.fromRateLimitTier(rateLimitTier) {
            return plan
        }

        let tier = Self.normalized(rateLimitTier)
        let billing = Self.normalized(billingType)
        if billing.contains("stripe"), tier.contains("claude") {
            return .pro
        }
        return nil
    }

    public static func fromCompatibilityLoginMethod(_ loginMethod: String?) -> Self? {
        let words = Self.normalizedWords(loginMethod)
        if words.isEmpty {
            return nil
        }
        if words.contains("max") {
            return .max
        }
        if words.contains("pro") {
            return .pro
        }
        if words.contains("team") {
            return .team
        }
        if words.contains("enterprise") {
            return .enterprise
        }
        if words.contains("ultra") {
            return .ultra
        }
        return nil
    }

    public static func oauthLoginMethod(rateLimitTier: String?) -> String? {
        self.fromOAuthRateLimitTier(rateLimitTier)?.brandedLoginMethod(rateLimitTier: rateLimitTier)
    }

    public static func oauthLoginMethod(subscriptionType: String?, rateLimitTier: String?) -> String? {
        self.fromOAuthCredentials(
            subscriptionType: subscriptionType,
            rateLimitTier: rateLimitTier)?.brandedLoginMethod(rateLimitTier: rateLimitTier)
    }

    public static func webLoginMethod(rateLimitTier: String?, billingType: String?) -> String? {
        self.fromWebAccount(
            rateLimitTier: rateLimitTier,
            billingType: billingType)?.brandedLoginMethod(rateLimitTier: rateLimitTier)
    }

    public static func cliCompatibilityLoginMethod(_ loginMethod: String?) -> String? {
        guard let loginMethod = loginMethod?.trimmingCharacters(in: .whitespacesAndNewlines),
              !loginMethod.isEmpty
        else {
            return nil
        }

        if let plan = self.fromCompatibilityLoginMethod(loginMethod) {
            return plan.compactLoginMethod
        }

        return loginMethod
    }

    public static func isSubscriptionLoginMethod(_ loginMethod: String?) -> Bool {
        self.fromCompatibilityLoginMethod(loginMethod)?.countsAsSubscription ?? false
    }

    private static func fromRateLimitTier(_ rateLimitTier: String?) -> Self? {
        let tier = Self.normalized(rateLimitTier)
        if tier.contains("max") {
            return .max
        }
        if tier.contains("pro") {
            return .pro
        }
        if tier.contains("team") {
            return .team
        }
        if tier.contains("enterprise") {
            return .enterprise
        }
        return nil
    }

    /// Extracts the usage multiplier ("5x" / "20x") that Anthropic encodes in the
    /// rate-limit tier string (e.g. "default_claude_max_20x").
    ///
    /// The multiplier is only surfaced when the tier string actually names the resolved
    /// plan. This keeps the label faithful to whatever tier Anthropic assigns — so a
    /// future `default_claude_team_5x` would render "Claude Team 5x" — while never
    /// leaking a stray multiplier onto a plan whose subscription type disagreed with the
    /// rate-limit tier (e.g. a Team subscription reported alongside a `max_5x` tier).
    private static func usageMultiplier(for plan: Self, rateLimitTier: String?) -> String? {
        let tier = Self.normalized(rateLimitTier)
        guard tier.contains(plan.rawValue) else {
            return nil
        }
        guard let range = tier.range(of: "[0-9]+x", options: .regularExpression) else {
            return nil
        }
        return String(tier[range])
    }

    private static func normalized(_ text: String?) -> String {
        text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private static func normalizedWords(_ text: String?) -> [String] {
        self.normalized(text)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}
