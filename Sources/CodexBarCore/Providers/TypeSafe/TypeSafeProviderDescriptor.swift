import Foundation
import SweetCookieKit

public enum TypeSafeProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(tokenAccountSupport: TokenAccountSupport(
        title: "Session cookies",
        subtitle: "Store multiple TypeSafe Cookie headers.",
        placeholder: "Cookie: …",
        injection: .cookieHeader,
        requiresManualCookieSource: true,
        cookieName: nil))

    /// Chrome-only by default to avoid extra Firefox/Safari Keychain and Full Disk Access prompts.
    /// Use Manual cookie source for other browsers.
    private static var browserCookieOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.chrome]
        #else
        nil
        #endif
    }

    static func makeDescriptor(
        transport: any ProviderHTTPTransport = TypeSafeWebFetchStrategy.isolatedTransport) -> ProviderDescriptor
    {
        let strategy = TypeSafeWebFetchStrategy(transport: transport)

        return ProviderDescriptor(
            id: .typesafe,
            menuBarMetrics: .automaticOnly,
            settingsSection: .init(TypeSafeProviderSettingsKey.self, cookieSettings: TypeSafeProviderSettings.self),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .typesafe,
                displayName: "TypeSafe",
                sessionLabel: "Spend",
                weeklyLabel: "Spend",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show TypeSafe usage",
                cliName: "typesafe",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: self.browserCookieOrder,
                dashboardURL: "https://console.typesafe.ai/usage",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .typesafe),
                iconResourceName: "ProviderIcon-typesafe",
                color: ProviderColor(hex: 0x111111),
                confettiPalette: [
                    ProviderColor(hex: 0x111111),
                    ProviderColor(hex: 0x555555),
                    ProviderColor(hex: 0xFFFFFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "TypeSafe spend comes from the billing summary page; cost history is not tracked." }),
            presentation: ProviderUsagePresentation(
                costPresenter: { snapshot in
                    // The pay-as-you-go card shows cycle spend, so drop the duplicate detail row when it renders.
                    let spentLabel = snapshot.providerCost?.period.map { "Spent (\($0))" } ?? "Spent"
                    return ProviderCostPresentation(
                        showsGenericFallback: false,
                        menuCardStyle: .payAsYouGoSpend,
                        replacedDetailRows: ["Billing": [spentLabel]])
                },
                planRow: ProviderPlanRowPresentation(label: "Balance", stripsBalancePrefix: true)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [strategy] })),
            cli: ProviderCLIConfig(
                name: "typesafe",
                aliases: [],
                versionDetector: nil,
                browserSupportExemption: { _, _, settings in
                    // Manual Cookie headers use plain HTTPS and never import browser data.
                    settings?.typesafe?.cookieSource == .manual
                }))
    }
}
