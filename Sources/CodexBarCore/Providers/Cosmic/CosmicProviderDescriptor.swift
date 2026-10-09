import Foundation

public enum CosmicProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .cosmic,
        displayName: "Cosmic AI",
        sessionLabel: "Input tokens",
        weeklyLabel: "Output tokens",
        dashboardURL: "https://app.cosmicjs.com",
        color: .init(hex: 0x29ABE2),
        confetti: [0x29ABE2, 0xA3DFF8],
        noDataMessage: "Cosmic AI cost history is not available.",
        environmentKey: "COSMIC_TOKEN",
        missingCredentialMessage: { _ in "Set a Cosmic Personal Access Token in Settings or COSMIC_TOKEN." },
        apiKeyField: .init(
            id: "cosmic-token",
            title: "Personal Access Token",
            subtitle: "Saved in CodexBar's local config file. Reads project usage only; bucket keys are not supported.",
            placeholder: "cos_…",
            action: ("cosmic-tokens", "Open Cosmic API tokens", "https://app.cosmicjs.com/account/api-tokens")),
        workspaceField: .init(
            environmentKey: "COSMIC_PROJECT_ID",
            field: .init(
                id: "cosmic-project-id",
                title: "Project ID",
                subtitle: "Required. Usage covers this project only. Or set COSMIC_PROJECT_ID.",
                placeholder: "Project ID")),
        availability: .configuredKey)
}
