import Foundation

public enum ManusProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(
        tokenAccountSupport: TokenAccountSupport(
            title: "Session tokens",
            subtitle: "Store multiple Manus session_id cookies.",
            placeholder: "session_id=…",
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: ManusCookieHeader.sessionCookieName),
        authDetector: { environment, _ in
            ManusSettingsReader.sessionToken(environment: environment) == nil ? [] : ["web"]
        })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .manus,
            settingsSection: .init(ManusProviderSettingsKey.self, cookieSettings: ManusProviderSettings.self),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .manus,
                displayName: "Manus",
                sessionLabel: "Monthly credits",
                weeklyLabel: "Daily refresh",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Manus usage",
                cliName: "manus",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "Manus debug log not yet implemented",
                usesDetailBackedWindow: true,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://manus.im",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .manus),
                iconResourceName: "ProviderIcon-manus",
                color: ProviderColor(red: 52 / 255, green: 50 / 255, blue: 45 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x34322D),
                    ProviderColor(hex: 0xF2F0E9),
                    ProviderColor(hex: 0x0099FF),
                ],
                widgetColor: ProviderColor(red: 24 / 255, green: 24 / 255, blue: 24 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Manus cost summary is not supported." }),
            presentation: ProviderUsagePresentation(
                costPresenter: { _ in ProviderCostPresentation(menuCardStyle: .hidden) },
                menuCard: ProviderMenuCardPresentation(
                    showsPrimaryBalanceDescription: true,
                    showsSecondaryBalanceDescription: true,
                    clearsPrimaryReset: true),
                menu: ProviderMenuDescriptorPresentation(
                    primaryDescriptionIsDetail: { _ in true },
                    secondaryDescriptionMode: .detailWhenResetDatePresent)),
            fetchPlan: self.fetchPlan(),
            cli: ProviderCLIConfig(
                name: "manus",
                aliases: [],
                versionDetector: nil))
    }

    private static func fetchPlan() -> ProviderFetchPlan {
        ProviderFetchPlan(
            sourceModes: [.auto, .web],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                [ScriptFetchStrategy(
                    id: "manus.js",
                    provider: .manus,
                    bundledPlugin: "manus",
                    sourceLabel: "web",
                    kind: .web,
                    resolveValues: { context in
                        guard context.settings?.manus?.cookieSource != .off else { return nil }
                        let token = ManusSettingsReader.sessionToken(environment: context.env)
                        return .init(secrets: token.map { ["SESSION_TOKEN": $0] } ?? [:])
                    }, isEnabled: { _ in true })]
            }))
    }
}
