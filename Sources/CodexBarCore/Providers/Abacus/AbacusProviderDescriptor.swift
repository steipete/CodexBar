import Foundation

#if os(macOS)
import SweetCookieKit
#endif

public enum AbacusProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    static let maximumCookieCandidates = 5
    private static let credentials = ProviderCredentialAdapter(tokenAccountSupport: TokenAccountSupport(
        title: "Session tokens",
        subtitle: "Store multiple Abacus AI Cookie headers.",
        placeholder: "Cookie: …",
        injection: .cookieHeader,
        requiresManualCookieSource: true,
        cookieName: nil))

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .abacus,
            settingsSection: .init(AbacusProviderSettingsKey.self, cookieSettings: AbacusProviderSettings.self),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .abacus,
                displayName: "Abacus AI",
                shortDisplayName: "Abacus",
                sessionLabel: "Credits",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Abacus AI usage",
                cliName: "abacusai",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                sharePlanLabels: ["basic": "Basic", "pro": "Pro", "team": "Team", "enterprise": "Enterprise"],
                usesDetailBackedWindow: true,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://apps.abacus.ai/chatllm/admin/compute-points-usage",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .abacus),
                iconResourceName: "ProviderIcon-abacus",
                color: ProviderColor(hex: 0x814EE8),
                confettiPalette: [
                    ProviderColor(hex: 0x814EE8),
                    ProviderColor(hex: 0xC64AF9),
                    ProviderColor(hex: 0xFFFFFF),
                ],
                widgetColor: ProviderColor(hex: 0x38BDF8)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Abacus AI cost summary is not supported." }),
            presentation: ProviderUsagePresentation(
                semanticWindowResolver: { .init(session: $0.primary, weekly: nil) },
                menuBarLayoutPrimaryLabel: "Credits",
                menuCard: ProviderMenuCardPresentation(usesAbacusPace: true),
                menu: ProviderMenuDescriptorPresentation(
                    primaryDescriptionIsDetail: { _ in true },
                    showsPrimaryWeeklyPace: true)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                    [Self.scriptStrategy(timeout: context.webTimeout)]
                })),
            cli: ProviderCLIConfig(
                name: "abacusai",
                aliases: ["abacus-ai"],
                versionDetector: nil))
    }

    static func refreshTimeout(for requestTimeout: TimeInterval) -> TimeInterval {
        min(90, requestTimeout * Double(self.maximumCookieCandidates) + min(requestTimeout, 5))
    }

    static func scriptStrategy(
        timeout: TimeInterval = 15,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) -> ScriptFetchStrategy
    {
        let requestTimeout = min(90, max(1, timeout))
        return ScriptFetchStrategy(
            id: "abacus.js",
            provider: .abacus,
            bundledPlugin: "abacus",
            sourceLabel: "web",
            kind: .web,
            transport: transport,
            timeout: Self.refreshTimeout(for: requestTimeout),
            cookieImport: { context, _, batch in
                #if os(macOS)
                guard batch < 2 else { return nil }
                let browsers = batch == 0 ? [Browser.chrome] :
                    (ProviderBrowserCookieDefaults.defaultImportOrder ?? Browser.defaultImportOrder)
                    .filter { $0 != .chrome }
                guard !browsers.isEmpty else { return nil }
                return AbacusCookieImporter.importSessions(
                    browserDetection: context.browserDetection, preferredBrowsers: browsers)
                    .map { ($0.cookieHeader, $0.sourceLabel) }
                #else
                return nil
                #endif
            },
            resolveValues: { context in
                guard context.settings?.abacus?.cookieSource != .off else { return nil }
                return .init(settings: [
                    "REQUEST_TIMEOUT": String(requestTimeout),
                    "MAX_COOKIE_CANDIDATES": String(Self.maximumCookieCandidates),
                ])
            }, isEnabled: { _ in true })
    }
}
