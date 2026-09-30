import Foundation

public enum ClinePassProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor(
        credentials: Self.credentials,
        fetchPlan: ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [Self.makeStrategy()] })))
    public static let spec = PluginProviderSpec(
        id: .clinepass,
        displayName: "ClinePass",
        sessionLabel: "5-hour",
        weeklyLabel: "Weekly",
        opusLabel: "Monthly",
        debugLogUnavailableMessage: "ClinePass debug log not yet implemented",
        dashboardURL: "https://app.cline.bot/dashboard/subscription?personal=true",
        color: ProviderColor(hex: 0x5487C8),
        confetti: [0x5487C8, 0x111111, 0xFFFFFF],
        widgetColor: ProviderColor(hex: 0x61A3FA),
        noDataMessage: "ClinePass cost history is not available via the usage-limits API.",
        environmentKey: "CLINE_API_KEY",
        environmentAliases: ["CLINEPASS_API_KEY"],
        presentation: ProviderUsagePresentation(primaryBindingQuotaLanes: [.secondary, .tertiary]),
        apiKeyField: .init(
            id: "clinepass-api-key",
            title: "API key",
            subtitle: "Paste an API key, or run cline auth. Reads the existing Cline session without copying it.",
            placeholder: "ClinePass API key..."),
        showsAPIDetail: true,
        availability: .configuredKey)

    private static let credentials = ProviderCredentialAdapter(
        supportsAPIKeyOverride: true,
        requiresAPIKeyForAPISource: false,
        environmentProjections: [.apiKey(Self.spec.environmentKey)],
        tokenResolver: { kind, environment, authFileURL in
            guard kind == .primary else { return nil }
            if let key = Self.spec.apiKey(environment: environment) {
                return ProviderTokenResolution(token: key, source: .environment)
            }
            guard let credential = ClinePassSettingsReader.fileCredential(
                environment: environment, authFileURL: authFileURL) else { return nil }
            return ProviderTokenResolution(token: credential.token, source: .authFile)
        },
        authDetector: { environment, _ in
            if Self.spec.apiKey(environment: environment) != nil { return ["api"] }
            guard let credential = ClinePassSettingsReader.fileCredential(environment: environment) else { return [] }
            return [credential.isOAuth ? "oauth" : "api"]
        },
        missingCredentialMessage: { _ in
            "ClinePass credentials not found. Add an API key or run cline auth to sign in."
        })

    static func makeStrategy(transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) -> ScriptFetchStrategy {
        ScriptFetchStrategy(
            id: "clinepass.js",
            provider: .clinepass,
            bundledPlugin: "clinepass",
            secretKey: self.spec.environmentKey,
            sourceLabel: "api",
            transport: transport,
            resolveValues: { context in
                if let values = Self.spec.scriptValues(context) { return values }
                guard let credential = ClinePassSettingsReader.fileCredential(environment: context.env)
                else { return nil }
                return .init(
                    settings: ["CLINE_AUTH_SOURCE": credential.isOAuth ? "oauth" : "api"],
                    secrets: [Self.spec.environmentKey: credential.token])
            },
            isEnabled: { _ in true })
    }
}
