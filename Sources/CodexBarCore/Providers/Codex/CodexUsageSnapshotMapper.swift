import Foundation

enum CodexUsageSnapshotMapper {
    static func usageSnapshot(
        from response: CodexUsageResponse,
        accountEmail: String?,
        fallbackLoginMethod: String?) -> UsageSnapshot
    {
        let primary = self.makeWindow(response.rateLimit?.primaryWindow)
        let secondary = self.makeWindow(response.rateLimit?.secondaryWindow)

        let resolvedPlan = response.planType?.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackPlan = fallbackLoginMethod?.trimmingCharacters(in: .whitespacesAndNewlines)
        let loginMethod = (resolvedPlan?.isEmpty == false) ? resolvedPlan : fallbackPlan
        let normalizedEmail = accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)

        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: normalizedEmail?.isEmpty == true ? nil : normalizedEmail,
            accountOrganization: nil,
            loginMethod: loginMethod?.isEmpty == true ? nil : loginMethod)

        return UsageSnapshot(
            primary: primary ?? RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: secondary,
            tertiary: nil,
            updatedAt: Date(),
            identity: identity)
    }

    static func creditsSnapshot(from credits: CodexUsageResponse.CreditDetails?) -> CreditsSnapshot? {
        guard let credits, let balance = credits.balance else { return nil }
        return CreditsSnapshot(remaining: balance, events: [], updatedAt: Date())
    }

    private static func makeWindow(_ window: CodexUsageResponse.WindowSnapshot?) -> RateWindow? {
        guard let window else { return nil }
        let resetDate = Date(timeIntervalSince1970: TimeInterval(window.resetAt))
        let resetDescription = UsageFormatter.resetDescription(from: resetDate)
        return RateWindow(
            usedPercent: Double(window.usedPercent),
            windowMinutes: window.limitWindowSeconds / 60,
            resetsAt: resetDate,
            resetDescription: resetDescription)
    }
}
