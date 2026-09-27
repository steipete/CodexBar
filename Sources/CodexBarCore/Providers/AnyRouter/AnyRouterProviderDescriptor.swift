import Foundation

public enum AnyRouterProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .anyrouter,
        displayName: "AnyRouter",
        sessionLabel: "Balance",
        weeklyLabel: "Balance",
        toggleTitle: "Show AnyRouter credit balance",
        balanceOnly: true,
        dashboardURL: "https://dash.anyrouter.dev",
        statusLinkURL: "https://anyrouter.dev/health",
        color: .init(hex: 0xF38020),
        confetti: [0xF38020, 0x0A0C10, 0xF6F7F9],
        noDataMessage: "AnyRouter credit history is not available.",
        environmentKey: "ANYROUTER_API_KEY",
        missingCredentialMessage: { _ in
            "Set an AnyRouter API key in Settings or ANYROUTER_API_KEY."
        },
        apiKeyField: .init(
            id: "anyrouter-api-key",
            title: "AnyRouter API key",
            subtitle: "Create a key at dash.anyrouter.dev with Management permissions. Or set ANYROUTER_API_KEY."))
}
