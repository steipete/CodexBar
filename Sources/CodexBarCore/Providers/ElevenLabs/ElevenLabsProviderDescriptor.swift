import Foundation

public enum ElevenLabsProviderDescriptor {
    private static let missingCredentialMessage =
        "Missing ElevenLabs API key. Set apiKey in ~/.codexbar/config.json or ELEVENLABS_API_KEY."
    public static let descriptor: ProviderDescriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .elevenlabs,
        displayName: "ElevenLabs",
        sessionLabel: "Credits",
        weeklyLabel: "Voices",
        sharePlanLabels: [
            "free": "Free", "starter": "Starter", "creator": "Creator", "pro": "Pro",
            "scale": "Scale", "business": "Business", "growing business": "Business",
            "enterprise": "Enterprise",
        ],
        dashboardURL: "https://elevenlabs.io/app/developers/usage",
        subscriptionDashboardURL: "https://elevenlabs.io/app/subscription",
        statusLinkURL: "https://status.elevenlabs.io",
        color: ProviderColor(red: 0.92, green: 0.92, blue: 0.90),
        confetti: [0x000000, 0x808080, 0xFDFCFC],
        widgetColor: ProviderColor(hex: 0xEBEBE6),
        progressColorStyle: .label,
        noDataMessage: "ElevenLabs cost history is not available via API yet.",
        environmentKey: ElevenLabsSettingsReader.apiKeyEnvironmentKey,
        environmentAliases: ["XI_API_KEY"],
        apiKeyDebugLabel: ElevenLabsSettingsReader.apiKeyEnvironmentKey,
        missingCredentialMessage: { _ in ElevenLabsProviderDescriptor.missingCredentialMessage },
        tokenAccountSupport: TokenAccountSupport(
            title: "API keys",
            subtitle: "Store multiple ElevenLabs API keys.",
            placeholder: "Paste API key…",
            injection: .environment(key: ElevenLabsSettingsReader.apiKeyEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil),
        aliases: ["11labs", "eleven"],
        scriptSettings: { context in
            var url = ElevenLabsSettingsReader.apiURL(environment: context.env)
            url.append(path: url.path.split(separator: "/").last == "v1" ? "user/subscription" : "v1/user/subscription")
            return ["BASE_URL": url.absoluteString]
        },
        validateContext: { context in
            guard ElevenLabsSettingsReader.apiKey(environment: context.env) != nil else {
                throw ProviderFetchClassifiedError(kind: .missingCredential, message: Self.missingCredentialMessage)
            }
            try ElevenLabsSettingsReader.validateEndpointOverrides(environment: context.env)
        },
        apiKeyField: .init(
            id: "elevenlabs-api-key",
            title: "API key",
            subtitle: "Stored in ~/.codexbar/config.json. Get your key from elevenlabs.io/app/settings/api-keys.",
            placeholder: "xi-..."),
        showsAPIDetail: true,
        availability: .configuredKeyOrAccount)
}
