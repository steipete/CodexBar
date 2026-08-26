import Foundation

public enum XquikProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: XquikSettingsReader.apiKeyEnvironmentKey,
        precedence: .environment,
        environmentHasValue: { XquikSettingsReader.apiKey(environment: $0) != nil },
        resolve: XquikSettingsReader.apiKey)

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .xquik,
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .xquik,
                displayName: "Xquik",
                sessionLabel: "Credits",
                weeklyLabel: "Credits",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Credit balance from the Xquik API",
                toggleTitle: "Show Xquik usage",
                cliName: "xquik",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                usesDetailBackedWindow: true,
                browserCookieOrder: nil,
                dashboardURL: "https://xquik.com",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .xquik),
                iconResourceName: "ProviderIcon-xquik",
                color: ProviderColor(red: 76 / 255, green: 38 / 255, blue: 38 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x4C2626),
                    ProviderColor(hex: 0xF5F3F0),
                    ProviderColor(hex: 0xA45A52),
                ],
                widgetColor: ProviderColor(red: 76 / 255, green: 38 / 255, blue: 38 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Xquik cost history is not available via API." }),
            presentation: ProviderUsagePresentation(
                menuCard: ProviderMenuCardPresentation(
                    primaryDescriptionPlacement: .detailBySecondaryPresence,
                    hidesPrimaryResetWithoutSecondary: true,
                    movePrimaryDetailToStatus: { $0?.secondary == nil }),
                menu: ProviderMenuDescriptorPresentation(
                    primaryDescriptionIsDetail: { $0.secondary == nil },
                    duplicatesPrimaryDetailWhenResetDatePresent: true,
                    secondaryDescriptionMode: .resetOverride)),
            fetchPlan: self.fetchPlan(),
            cli: ProviderCLIConfig(
                name: "xquik",
                versionDetector: nil))
    }

    private static func fetchPlan() -> ProviderFetchPlan {
        ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                [ScriptFetchStrategy(
                    id: "xquik.js",
                    provider: .xquik,
                    bundledPlugin: "xquik",
                    secretKey: XquikSettingsReader.apiKeyEnvironmentKey,
                    sourceLabel: "api",
                    resolveSecret: { environment in
                        self.credentials.resolveToken(environment: environment)?.token
                    },
                    isEnabled: { _ in true })]
            }))
    }
}
