import Foundation

public enum AbliterationProviderDescriptor {
    static let diagnosticMessages = [
        "Check your API key in Settings.",
        "abliteration.ai is rate limiting requests. Try again later.",
        "abliteration.ai request failed. Try refreshing later.",
        "abliteration.ai returned an unrecognized response. Update CodexBar and try again.",
    ]

    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .abliteration,
        displayName: "abliteration.ai",
        sessionLabel: "Credits",
        weeklyLabel: "Usage",
        usesDetailBackedWindow: true,
        dashboardURL: "https://abliteration.ai",
        color: .init(hex: 0x1B1B1B),
        confetti: [0x1B1B1B, 0xECE8E6],
        progressColorStyle: .label,
        noDataMessage: "No cost history data.",
        history: .unavailable,
        burnDownWidgetSelectable: false,
        environmentKey: "ABLITERATION_API_KEY",
        missingCredentialMessage: { _ in UsageFormatter.localized("Check your API key in Settings.") },
        menuBarMetrics: .init(supported: [.automatic, .primary]),
        presentation: ProviderUsagePresentation(
            menuBarBalanceDetailLabels: ["Balance"],
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
            id: "abliteration-api-key",
            title: "API key",
            subtitle: "Stored in the CodexBar config file."),
        showsAPIDetail: true,
        availability: .configuredKey)
}
