import Foundation

public struct ProxyUsageBridge: Sendable {
    public init() {}

    public func toUsageSnapshot(entry: ProxyTokenEntry, provider: UsageProvider) -> UsageSnapshot {
        let totalDisplay = Self.formatTokenCount(entry.totalTokens)
        let promptDisplay = Self.formatTokenCount(entry.promptTokens)
        let completionDisplay = Self.formatTokenCount(entry.completionTokens)

        let primaryWindow = RateWindow(
            usedPercent: 0,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: "Today: \(totalDisplay) tokens")

        let secondaryWindow = RateWindow(
            usedPercent: 0,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: "In: \(promptDisplay) / Out: \(completionDisplay)")

        let identity = ProviderIdentitySnapshot(
            providerID: provider,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "proxy")

        return UsageSnapshot(
            primary: primaryWindow,
            secondary: secondaryWindow,
            tertiary: nil,
            providerCost: nil,
            updatedAt: entry.timestamp,
            identity: identity)
    }

    private static func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}
