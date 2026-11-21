import Foundation

public enum TrustedRouterProviderDescriptor {
    static let diagnosticMessages = [
        "Check your API key in Settings.",
        "TrustedRouter is rate limiting requests. Try again later.",
        "TrustedRouter request failed. Try refreshing later.",
        "TrustedRouter returned an unrecognized response. Update CodexBar and try again.",
    ]

    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .trustedrouter,
        displayName: "TrustedRouter",
        sessionLabel: "Limit",
        weeklyLabel: "Usage",
        usesDetailBackedWindow: true,
        dashboardURL: "https://trustedrouter.com/console",
        color: .init(hex: 0xA9CDB9),
        confetti: [0xA9CDB9, 0xEDE8DB],
        progressColorStyle: .label,
        noDataMessage: "No cost history data.",
        history: .unavailable,
        burnDownWidgetSelectable: false,
        environmentKey: "TRUSTEDROUTER_API_KEY",
        missingCredentialMessage: { _ in UsageFormatter.localized("Check your API key in Settings.") },
        menuBarMetrics: .init(supported: [.automatic, .primary]),
        presentation: ProviderUsagePresentation(
            menuBarBalanceDetailLabels: ["Remaining"],
            menuCard: ProviderMenuCardPresentation(
                primaryDescriptionPlacement: .detail,
                hidesPrimaryResetWithoutDate: true)),
        scriptSettings: { _ in
            let messages = Dictionary(uniqueKeysWithValues: Self.diagnosticMessages.map {
                ($0, UsageFormatter.localized($0))
            })
            let data = try? JSONEncoder().encode(messages)
            return ["MESSAGES": data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"]
        },
        apiKeyField: .init(
            id: "trustedrouter-api-key",
            title: "API key",
            subtitle: "Stored in the CodexBar config file.",
            action: ("trustedrouter-api-keys", "API keys", "https://trustedrouter.com/console/api-keys")),
        showsAPIDetail: true,
        availability: .configuredKey)
}
