import Foundation
import SweetCookieKit

public enum LongCatProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(environmentProjections: [
        .cookieHeader(LongCatSettingsReader.cookieHeaderKey, onlyWhenManual: true),
    ])

    /// Preserve Chrome-first behavior, then check Firefox without adding another Keychain prompt.
    private static var browserCookieOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.chrome, .firefox]
        #else
        nil
        #endif
    }

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .longcat,
            settingsSection: .init(LongCatProviderSettingsKey.self, cookieSettings: LongCatProviderSettings.self),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .longcat,
                displayName: "LongCat",
                sessionLabel: "Quota",
                weeklyLabel: "Fuel Pack",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show LongCat usage",
                cliName: "longcat",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                usesDetailBackedWindow: true,
                browserCookieOrder: self.browserCookieOrder,
                dashboardURL: "https://longcat.chat/platform/",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .longcat),
                iconResourceName: "ProviderIcon-longcat",
                color: ProviderColor(hex: 0x29E154),
                confettiPalette: [
                    ProviderColor(hex: 0x29E154),
                    ProviderColor(hex: 0x111111),
                    ProviderColor(hex: 0xFFFFFF),
                ],
                widgetColor: ProviderColor(hex: 0xFFD100)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "LongCat cost summary is not supported." }),
            presentation: ProviderUsagePresentation(
                menuCard: ProviderMenuCardPresentation(
                    showsPrimaryBalanceDescription: true,
                    showsSecondaryBalanceDescription: true,
                    hidesPrimaryResetWithoutDate: true),
                menu: ProviderMenuDescriptorPresentation(
                    primaryDescriptionIsDetail: { _ in true },
                    secondaryDescriptionMode: .detailWhenResetDatePresent)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [Self.webStrategy()] })),
            cli: ProviderCLIConfig(
                name: "longcat",
                aliases: ["long-cat", "lc"],
                versionDetector: nil))
    }
}

extension LongCatProviderDescriptor {
    static func webStrategy(transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) -> ScriptFetchStrategy {
        ScriptFetchStrategy(
            id: "longcat.web",
            provider: .longcat,
            bundledPlugin: "longcat",
            sourceLabel: "web",
            kind: .web,
            transport: transport,
            cookieSettings: self.cookieSettings,
            resolveValues: { _ in .init() },
            isEnabled: { _ in true })
    }

    static func cookieSettings(_ context: ProviderFetchContext) -> ProviderSettingsSnapshot.CookieProviderSettings {
        let settings = context.settings?.longcat
        let source = settings?.cookieSource ?? .auto
        guard source != .off else { return .init(cookieSource: .off, manualCookieHeader: nil) }
        let manual = source == .manual ? settings?.manualCookieHeader : nil
        let raw = manual?.isEmpty == false ? manual : LongCatSettingsReader.cookieHeader(environment: context.env)
        if let header = CookieHeaderNormalizer.normalize(raw), header.contains("=") {
            return .init(cookieSource: .manual, manualCookieHeader: header)
        }
        return .init(cookieSource: source, manualCookieHeader: nil)
    }
}
