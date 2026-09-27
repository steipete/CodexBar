import Foundation

public enum PoeProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .poe,
        displayName: "Poe",
        sessionLabel: "Points",
        weeklyLabel: "Points",
        balanceOnly: true,
        dashboardURL: "https://poe.com/api/keys",
        color: .init(hex: 0x5D5CDE),
        confetti: [0x5D5CDE, 0x2A2AA2, 0xE051ED],
        noDataMessage: "Poe usage history is unavailable.",
        environmentKey: "POE_API_KEY",
        presentation: ProviderUsagePresentation(
            menuCard: ProviderMenuCardPresentation(primaryDetailKind: .poeBalance),
            planRow: ProviderPlanRowPresentation(label: "Balance", stripsBalancePrefix: true)),
        apiKeyField: .init(
            id: "poe-api-key",
            title: "API key",
            subtitle: "Stored in ~/.codexbar/config.json. Get your key from poe.com/api/keys.",
            placeholder: nil),
        showsAPIDetail: true,
        availability: .configuredKey)
}
