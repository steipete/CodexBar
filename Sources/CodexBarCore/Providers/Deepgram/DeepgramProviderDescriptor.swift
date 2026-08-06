import Foundation

public enum DeepgramProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(
        supportsAPIKeyOverride: true,
        environmentProjections: [
            .apiKey(DeepgramSettingsReader.apiKeyEnvironmentKey),
            .workspaceID(DeepgramSettingsReader.projectIDEnvironmentKey),
        ],
        tokenResolver: { kind, environment, _ in
            let value: String? = switch kind {
            case .primary: DeepgramSettingsReader.apiKey(environment: environment)
            case .projectID: DeepgramSettingsReader.projectID(environment: environment)
            case .secondary: nil
            }
            guard let value else { return nil }
            return ProviderTokenResolution(token: value, source: .environment)
        },
        authDetector: { environment, _ in
            DeepgramSettingsReader.apiKey(environment: environment) == nil ? [] : ["api"]
        })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .deepgram,
            credentials: self.credentials,
            config: ProviderConfigCapabilities(workspaceIDValidationOrder: 5),
            metadata: ProviderMetadata(
                id: .deepgram,
                displayName: "Deepgram",
                sessionLabel: "Requests",
                weeklyLabel: "Usage",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Usage summary from Deepgram API",
                toggleTitle: "Show Deepgram usage",
                cliName: "deepgram",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "Deepgram debug log not yet implemented",
                browserCookieOrder: nil,
                dashboardURL: "https://console.deepgram.com/project/",
                statusPageURL: nil,
                statusLinkURL: "https://status.deepgram.com"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .deepgram),
                iconResourceName: "ProviderIcon-deepgram",
                color: ProviderColor(
                    red: 100 / 255,
                    green: 103 / 255,
                    blue: 242 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x13EF95),
                    ProviderColor(hex: 0x149AFB),
                    ProviderColor(hex: 0x1A1A1F),
                ],
                widgetColor: ProviderColor(red: 10 / 255, green: 18 / 255, blue: 27 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: {
                    "Deepgram cost summary is not yet supported."
                }),
            fetchPlan: self.fetchPlan(),
            cli: ProviderCLIConfig(
                name: "deepgram",
                aliases: ["dg"],
                versionDetector: nil))
    }

    private static func fetchPlan() -> ProviderFetchPlan {
        #if canImport(JavaScriptCore)
        ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                [ScriptFetchStrategy(
                    id: "deepgram.js",
                    provider: .deepgram,
                    bundledPlugin: "deepgram",
                    secretKey: DeepgramSettingsReader.apiKeyEnvironmentKey,
                    sourceLabel: "api",
                    validateContext: { context in
                        try DeepgramSettingsReader.validateEndpointOverride(environment: context.env)
                    },
                    resolveValues: { context in
                        guard let key = self.credentials.resolveToken(
                            environment: context.env)?.token
                        else { return nil }
                        var settings = [
                            DeepgramSettingsReader.apiURLEnvironmentKey:
                                DeepgramSettingsReader.apiURL(environment: context.env).absoluteString,
                        ]
                        if let project = self.credentials.resolveToken(
                            kind: .projectID,
                            environment: context.env)?.token
                        {
                            settings[DeepgramSettingsReader.projectIDEnvironmentKey] = project
                        }
                        return ScriptFetchStrategy.Values(
                            settings: settings,
                            secrets: [DeepgramSettingsReader.apiKeyEnvironmentKey: key])
                    },
                    isEnabled: { _ in true })]
            }))
        #else
        // Linux compatibility only. JavaScriptCore platforms use the bundled Deepgram plugin above.
        ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [DeepgramAPIFetchStrategy()] }))
        #endif
    }
}

#if !canImport(JavaScriptCore)
struct DeepgramAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "deepgram.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveAPIKey(context) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveAPIKey(context) else {
            throw DeepgramSettingsError.missingToken
        }

        let usage = try await DeepgramUsageFetcher.fetchUsage(
            apiKey: apiKey,
            projectID: Self.resolveProjectID(context),
            environment: context.env)

        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func resolveAPIKey(_ context: ProviderFetchContext) -> String? {
        ProviderTokenResolver.deepgramResolution(
            type: .apiKey,
            environment: context.env)
    }

    private static func resolveProjectID(_ context: ProviderFetchContext) -> String? {
        ProviderTokenResolver.deepgramResolution(
            type: .projectID,
            environment: context.env)
    }
}
#endif

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
