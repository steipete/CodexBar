import Foundation

public enum FloraProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .flora,
        displayName: "FLORA",
        sessionLabel: "Balance",
        weeklyLabel: "Balance",
        toggleTitle: "Show FLORA balance",
        balanceOnly: true,
        dashboardURL: "https://app.flora.ai",
        color: .init(hex: 0x111111),
        confetti: [0x111111, 0x8C8C8C],
        noDataMessage: "No cost history data.",
        environmentKey: "FLORA_API_KEY",
        missingCredentialMessage: { _ in "Set a FLORA API key in Settings or FLORA_API_KEY." },
        presentation: ProviderUsagePresentation(menuBarBalanceDetailLabels: ["Available"]),
        apiKeyField: .init(
            id: "flora-api-key",
            title: "API key",
            subtitle: "Needs billing permission on the workspace. Or set FLORA_API_KEY.",
            placeholder: "ak_…",
            action: (
                "flora-api-keys",
                "Open FLORA API keys",
                "https://app.flora.ai/projects?openSettings=true&initialTab=apiKeys")),
        workspaceField: .init(
            environmentKey: "FLORA_WORKSPACE_ID",
            field: .init(
                id: "flora-workspace-id",
                title: "Workspace ID",
                subtitle: "Required. The ws_… ID of the workspace the key can bill. Or set FLORA_WORKSPACE_ID.",
                placeholder: "ws_…")),
        availability: .configuredKey)
}
