import Foundation

public enum ReplicateProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(tokenAccountSupport: TokenAccountSupport(
        title: "Session tokens",
        subtitle: "Store multiple Replicate Cookie headers.",
        placeholder: "Cookie: …",
        injection: .cookieHeader,
        requiresManualCookieSource: true,
        cookieName: nil))

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .replicate,
            menuBarMetrics: ProviderMenuBarMetricCapabilities(supported: [.automatic]),
            settingsSection: .init(ReplicateProviderSettingsKey.self, cookieSettings: ReplicateProviderSettings.self),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .replicate,
                displayName: "Replicate",
                sessionLabel: "Spend",
                weeklyLabel: "Spend",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Replicate usage",
                cliName: "replicate",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://replicate.com/account/billing",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .replicate),
                iconResourceName: "ProviderIcon-replicate",
                color: ProviderColor(red: 0 / 255, green: 0 / 255, blue: 0 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x000000),
                    ProviderColor(hex: 0x525252),
                    ProviderColor(hex: 0xFFFFFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Replicate spend comes from the billing summary page; cost history is not tracked." }),
            presentation: ProviderUsagePresentation(
                costPresenter: { _ in
                    ProviderCostPresentation(showsGenericFallback: false, menuCardStyle: .hidden)
                }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [ReplicateWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "replicate",
                aliases: ["r8"],
                versionDetector: nil,
                browserSupportExemption: { _, _, settings in
                    // Manual Cookie headers use plain HTTPS and never import browser data.
                    settings?.replicate?.cookieSource == .manual
                }))
    }
}
