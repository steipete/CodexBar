import Foundation
import SweetCookieKit

public enum HuggingFaceProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    /// Hugging Face sessions are imported from Chrome; avoid probing unrelated browser keychains.
    private static var browserCookieOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.chrome]
        #else
        nil
        #endif
    }

    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: HuggingFaceSettingsReader.tokenEnvironmentKey,
        apiKeyDebugLabel: HuggingFaceSettingsReader.tokenEnvironmentKey,
        resolve: HuggingFaceSettingsReader.token,
        tokenAccountSupport: TokenAccountSupport(
            title: "API tokens",
            subtitle: "Store multiple Hugging Face user access tokens.",
            placeholder: "hf_...",
            injection: .environment(key: HuggingFaceSettingsReader.tokenEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil),
        missingCredentialMessage: { _ in HuggingFaceSettingsError.missingToken.errorDescription })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .huggingface,
            settingsSection: .init(
                HuggingFaceProviderSettingsKey.self,
                cookieSettings: HuggingFaceProviderSettings.self),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .huggingface,
                displayName: "Hugging Face",
                shortDisplayName: "HF",
                sessionLabel: "Spend",
                weeklyLabel: "Spend",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Spend reported by Hugging Face billing",
                toggleTitle: "Show Hugging Face usage",
                cliName: "huggingface",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: self.browserCookieOrder,
                dashboardURL: "https://huggingface.co/settings/billing",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .huggingface),
                iconResourceName: "ProviderIcon-huggingface",
                color: ProviderColor(hex: 0xFFD21E),
                confettiPalette: [
                    ProviderColor(hex: 0xFFD21E),
                    ProviderColor(hex: 0xFF9D00),
                    ProviderColor(hex: 0x2D2D2D),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: {
                    "Hugging Face billing reports spend for returned categories; " +
                        "this integration does not provide daily request history."
                }),
            presentation: ProviderUsagePresentation(
                costPresenter: { snapshot in
                    guard let cost = snapshot.providerCost else { return ProviderCostPresentation() }
                    let balances = cost.balance.map {
                        [ProviderCostPresentation.Balance(
                            label: "Credits",
                            amount: $0,
                            currencyCode: cost.currencyCode)]
                    } ?? []
                    if cost.period == "Prepaid credits" {
                        return ProviderCostPresentation(
                            showsGenericFallback: false,
                            balances: balances,
                            menuCardStyle: .prepaidCredits)
                    }
                    return ProviderCostPresentation(
                        balances: balances,
                        menuCardStyle: cost.balance == nil ? .apiSpend : .payAsYouGoSpend)
                },
                menuCard: ProviderMenuCardPresentation(providerCostIsRequiredUsage: true),
                optionalDetails: ProviderOptionalDetailsPresentation(
                    costSummaryTitles: ["Billing summary"])),
            fetchPlan: self.fetchPlan(),
            cli: ProviderCLIConfig(
                name: "huggingface",
                aliases: ["hf"],
                versionDetector: nil))
    }

    private static func fetchPlan() -> ProviderFetchPlan {
        let api = self.apiStrategy()
        return ProviderFetchPlan(
            sourceModes: [.auto, .api, .web],
            pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                switch context.sourceMode {
                case .api, .cli, .oauth:
                    [api]
                case .web:
                    [HuggingFaceWebFetchStrategy()]
                case .auto:
                    [HuggingFaceAutoFetchStrategy(
                        apiStrategy: api,
                        webStrategy: HuggingFaceWebFetchStrategy())]
                }
            }))
    }

    private static func apiStrategy() -> ScriptFetchStrategy {
        ScriptFetchStrategy(
            id: "huggingface.js",
            provider: .huggingface,
            bundledPlugin: "huggingface",
            secretKey: HuggingFaceSettingsReader.tokenEnvironmentKey,
            sourceLabel: "api",
            resolveSecret: { environment in
                self.credentials.resolveToken(environment: environment)?.token
            },
            isEnabled: { _ in true })
    }
}
