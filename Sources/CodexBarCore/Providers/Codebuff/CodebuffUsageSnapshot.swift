import Foundation

/// Parsed view of a Codebuff usage + subscription response pair.
public struct CodebuffUsageSnapshot: Sendable {
    public let creditsUsed: Double?
    public let creditsTotal: Double?
    public let creditsRemaining: Double?
    public let weeklyUsed: Double?
    public let weeklyLimit: Double?
    public let billingPeriodEnd: Date?
    public let nextQuotaReset: Date?
    public let tier: String?
    public let subscriptionStatus: String?
    public let autoTopUpEnabled: Bool?
    public let accountEmail: String?
    public let updatedAt: Date

    public init(
        creditsUsed: Double? = nil,
        creditsTotal: Double? = nil,
        creditsRemaining: Double? = nil,
        weeklyUsed: Double? = nil,
        weeklyLimit: Double? = nil,
        billingPeriodEnd: Date? = nil,
        nextQuotaReset: Date? = nil,
        tier: String? = nil,
        subscriptionStatus: String? = nil,
        autoTopUpEnabled: Bool? = nil,
        accountEmail: String? = nil,
        updatedAt: Date = Date())
    {
        self.creditsUsed = creditsUsed
        self.creditsTotal = creditsTotal
        self.creditsRemaining = creditsRemaining
        self.weeklyUsed = weeklyUsed
        self.weeklyLimit = weeklyLimit
        self.billingPeriodEnd = billingPeriodEnd
        self.nextQuotaReset = nextQuotaReset
        self.tier = tier
        self.subscriptionStatus = subscriptionStatus
        self.autoTopUpEnabled = autoTopUpEnabled
        self.accountEmail = accountEmail
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let primary = self.makeCreditsWindow()
        let secondary = self.makeWeeklyWindow()

        let identity = ProviderIdentitySnapshot(
            providerID: .codebuff,
            accountEmail: self.accountEmail,
            accountOrganization: nil,
            loginMethod: self.makeLoginMethod())

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private func makeCreditsWindow() -> RateWindow? {
        let total = self.resolvedTotal
        guard let total, total > 0 else {
            if self.creditsRemaining != nil || self.creditsUsed != nil {
                // Degenerate case: no usable quota in the payload. Surface the row as fully
                // exhausted so missing quota data is visibly surfaced (matches Kilo's behaviour
                // for zero/unknown totals) rather than rendering a misleading healthy bar.
                return RateWindow(
                    usedPercent: 100,
                    windowMinutes: nil,
                    resetsAt: self.nextQuotaReset,
                    resetDescription: nil)
            }
            return nil
        }
        let used = self.resolvedUsed
        let percent = min(100, max(0, (used / total) * 100))
        let usedText = Self.compactNumber(used)
        let totalText = Self.compactNumber(total)
        return RateWindow(
            usedPercent: percent,
            windowMinutes: nil,
            resetsAt: self.nextQuotaReset,
            resetDescription: "\(usedText)/\(totalText) credits")
    }

    private func makeWeeklyWindow() -> RateWindow? {
        guard let limit = self.weeklyLimit, limit > 0 else { return nil }
        let used = max(0, self.weeklyUsed ?? 0)
        let percent = min(100, max(0, (used / limit) * 100))
        return RateWindow(
            usedPercent: percent,
            windowMinutes: 7 * 24 * 60,
            resetsAt: nil,
            resetDescription: "\(Self.compactNumber(used))/\(Self.compactNumber(limit)) weekly")
    }

    private var resolvedTotal: Double? {
        if let creditsTotal { return max(0, creditsTotal) }
        if let creditsUsed, let creditsRemaining {
            return max(0, creditsUsed + creditsRemaining)
        }
        return nil
    }

    private var resolvedUsed: Double {
        if let creditsUsed {
            return max(0, creditsUsed)
        }
        if let total = self.resolvedTotal, let creditsRemaining {
            return max(0, total - creditsRemaining)
        }
        return 0
    }

    private func makeLoginMethod() -> String? {
        var parts: [String] = []
        if let tier = self.tier?.trimmingCharacters(in: .whitespacesAndNewlines), !tier.isEmpty {
            parts.append(tier.capitalized)
        }
        if let remaining = self.creditsRemaining {
            parts.append("\(Self.compactNumber(remaining)) remaining")
        }
        if self.autoTopUpEnabled == true {
            parts.append("auto top-up")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func compactNumber(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = value >= 1000 ? 0 : 1
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
    }
}
