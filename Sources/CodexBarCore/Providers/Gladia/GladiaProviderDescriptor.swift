import Foundation

public enum GladiaProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .gladia,
        displayName: "Gladia",
        sessionLabel: "Usage",
        weeklyLabel: "Usage",
        dashboardURL: "https://app.gladia.io",
        statusPageURL: "https://status.gladia.io",
        color: ProviderColor(hex: 0x947AFC),
        confetti: [0x947AFC, 0x0C0C0C],
        noDataMessage: "No cost history data.",
        environmentKey: "GLADIA_API_KEY",
        missingCredentialMessage: { _ in "Set a Gladia API key in Settings or GLADIA_API_KEY." },
        apiKeyField: .init(
            id: "gladia-api-key",
            title: "API key",
            subtitle: "Stored in the CodexBar config file.",
            action: (
                id: "gladia-api-key-guide",
                title: "Open API Keys",
                url: "https://app.gladia.io/apikeys")),
        showsAPIDetail: true,
        availability: .configuredKey)
}
