import Foundation

public enum DeepgramProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .deepgram,
        displayName: "Deepgram",
        sessionLabel: "Requests",
        weeklyLabel: "Usage",
        creditsHint: "Usage summary from Deepgram API",
        debugLogUnavailableMessage: "Deepgram debug log not yet implemented",
        dashboardURL: "https://console.deepgram.com/project/",
        statusLinkURL: "https://status.deepgram.com",
        color: ProviderColor(hex: 0x6467F2),
        confetti: [0x13EF95, 0x149AFB, 0x1A1A1F],
        widgetColor: ProviderColor(hex: 0x0A121B),
        noDataMessage: "Deepgram cost summary is not yet supported.",
        environmentKey: DeepgramSettingsReader.apiKeyEnvironmentKey,
        config: ProviderConfigCapabilities(workspaceIDValidationOrder: 5),
        aliases: ["dg"],
        scriptSettings: { context in
            [DeepgramSettingsReader.apiURLEnvironmentKey:
                DeepgramSettingsReader.apiURL(environment: context.env).absoluteString]
        },
        validateContext: { context in
            try DeepgramSettingsReader.validateEndpointOverride(environment: context.env)
        },
        apiKeyField: .init(
            id: "deepgram-api-key",
            title: "API key",
            subtitle: "Stored in ~/.codexbar/config.json. Get your key from console.deepgram.com.",
            placeholder: "dg_..."),
        workspaceField: .init(
            environmentKey: DeepgramSettingsReader.projectIDEnvironmentKey,
            field: .init(
                id: "deepgram-project-id",
                title: "Project ID",
                subtitle: "Optional. Leave blank to discover and aggregate projects visible to the API key.",
                placeholder: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"),
            resolvesProjectID: true),
        showsAPIDetail: true,
        availability: .configuredKey)
}

/// Errors related to Deepgram settings
public enum DeepgramSettingsError: LocalizedError, Sendable {
    case missingToken
    case invalidEndpointOverride(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "Deepgram API token not configured. Set DEEPGRAM_API_KEY environment variable or configure in Settings."
        case let .invalidEndpointOverride(key):
            "Deepgram endpoint override \(key) must use HTTPS or a bare host."
        }
    }
}
