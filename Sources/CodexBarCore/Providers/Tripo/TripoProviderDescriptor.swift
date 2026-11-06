import Foundation

public enum TripoProviderDescriptor {
    static let diagnosticMessages = [
        "Check your API key in Settings.",
        "Tripo is rate limiting requests. Try again later.",
        "Tripo request failed. Try refreshing later.",
        "Tripo returned an unrecognized response. Update CodexBar and try again.",
    ]

    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .tripo,
        displayName: "Tripo",
        sessionLabel: "Credits",
        weeklyLabel: "Credits",
        balanceOnly: true,
        dashboardURL: "https://developers.tripo3d.ai/en/billing",
        statusPageURL: "https://tripo3d.statuspage.io",
        color: .init(hex: 0xF8CF00),
        confetti: [0xF8CF00, 0xFFF3B0],
        noDataMessage: "No cost history data.",
        history: .unavailable,
        burnDownWidgetSelectable: false,
        environmentKey: "TRIPO_API_KEY",
        missingCredentialMessage: { _ in UsageFormatter.localized("Check your API key in Settings.") },
        scriptSettings: { _ in
            let messages = Dictionary(uniqueKeysWithValues: Self.diagnosticMessages.map {
                ($0, UsageFormatter.localized($0))
            })
            let data = try? JSONEncoder().encode(messages)
            return ["MESSAGES": data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"]
        },
        apiKeyField: .init(
            id: "tripo-api-key",
            title: "API key",
            subtitle: "Stored in the CodexBar config file.",
            action: ("tripo-api-keys", "API keys", "https://developers.tripo3d.ai/en/keys")),
        showsAPIDetail: true,
        availability: .configuredKey)
}
