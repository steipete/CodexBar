import Foundation

public enum TypeSafeProviderDescriptor {
    public static let descriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(tokenAccountSupport: TokenAccountSupport(
        title: "Session cookies",
        subtitle: "Store multiple TypeSafe Cookie headers.",
        placeholder: "Cookie: …",
        injection: .cookieHeader,
        requiresManualCookieSource: true,
        cookieName: nil))

    private static let spec = PluginProviderSpec(
        id: .typesafe,
        displayName: "TypeSafe",
        sessionLabel: "Spend",
        weeklyLabel: "Spend",
        dashboardURL: "https://console.typesafe.ai/usage",
        color: ProviderColor(hex: 0x111111),
        confetti: [0x111111, 0x555555, 0xFFFFFF],
        noDataMessage: "No cost history data.",
        menuBarMetrics: .automaticOnly,
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
        webSource: .init(
            settingsSection: .init(TypeSafeProviderSettingsKey.self, cookieSettings: TypeSafeProviderSettings.self),
            browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
            browserSupportExemption: { _, _, settings in settings?.typesafe?.cookieSource == .manual },
            field: .init(
                id: "typesafe-cookie-header",
                title: "Cookie header",
                subtitle: "Paste the Cookie header from a billing-page request.")))

    static func makeDescriptor(
        transport: any ProviderHTTPTransport = TypeSafeWebFetchStrategy.isolatedTransport) -> ProviderDescriptor
    {
        let strategy = TypeSafeWebFetchStrategy(transport: transport)
        return self.spec.makeDescriptor(
            credentials: self.credentials,
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [strategy] })))
    }
}
