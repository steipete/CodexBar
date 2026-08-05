import Foundation

public enum CrofProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: CrofSettingsReader.apiKeyEnvironmentKeys[0],
        precedence: .environment,
        environmentHasValue: { CrofSettingsReader.apiKey(environment: $0) != nil },
        resolve: CrofSettingsReader.apiKey)

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .crof,
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .crof,
                displayName: "Crof",
                sessionLabel: "Credits",
                weeklyLabel: "Credits",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Credit balance from the Crof usage API",
                toggleTitle: "Show Crof usage",
                cliName: "crof",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://crof.ai/dashboard",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .crof),
                iconResourceName: "ProviderIcon-crof",
                color: ProviderColor(red: 0.18, green: 0.67, blue: 0.58),
                confettiPalette: [
                    ProviderColor(hex: 0x0A0A0A),
                    ProviderColor(hex: 0x8B7CFF),
                    ProviderColor(hex: 0xA99FFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Crof cost summary is not available via API." }),
            fetchPlan: self.fetchPlan(),
            cli: ProviderCLIConfig(
                name: "crof",
                aliases: ["crofai"],
                versionDetector: nil))
    }

    private static func fetchPlan() -> ProviderFetchPlan {
        #if canImport(JavaScriptCore)
        ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                [ScriptFetchStrategy(
                    id: "crof.js",
                    provider: .crof,
                    bundledPlugin: "crof",
                    secretKey: CrofSettingsReader.apiKeyEnvironmentKeys[0],
                    sourceLabel: "api",
                    resolveSecret: { environment in
                        self.credentials.resolveToken(environment: environment)?.token
                    },
                    isEnabled: { _ in true })]
            }))
        #else
        // Linux compatibility only. JavaScriptCore platforms use the bundled plugin above.
        .apiToken(
            strategyID: "crof.api",
            resolveToken: { ProviderTokenResolver.crofToken(environment: $0) },
            missingCredentialsError: { CrofUsageError.missingCredentials },
            loadUsage: { apiKey, _ in
                try await CrofUsageFetcher.fetchUsage(apiKey: apiKey).toUsageSnapshot()
            })
        #endif
    }

    public static func primaryLabel(snapshot: UsageSnapshot) -> String {
        snapshot.secondary == nil ? "Credits" : "Requests"
    }
}
