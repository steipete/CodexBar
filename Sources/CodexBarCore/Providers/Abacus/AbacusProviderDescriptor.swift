import Foundation

#if os(macOS)
import SweetCookieKit
#endif

public enum AbacusProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
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
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://apps.abacus.ai/chatllm/admin/compute-points-usage",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .abacus),
                iconResourceName: "ProviderIcon-abacus",
                color: ProviderColor(red: 129 / 255, green: 78 / 255, blue: 232 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x814EE8),
                    ProviderColor(hex: 0xC64AF9),
                    ProviderColor(hex: 0xFFFFFF),
                ],
                widgetColor: ProviderColor(red: 56 / 255, green: 189 / 255, blue: 248 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Abacus AI cost summary is not supported." }),
            presentation: ProviderUsagePresentation(
                menuCard: ProviderMenuCardPresentation(usesAbacusPace: true),
                menu: ProviderMenuDescriptorPresentation(
                    primaryDescriptionIsDetail: { _ in true },
                    showsPrimaryWeeklyPace: true)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                    [AbacusWebFetchStrategy()]
                })),
            cli: ProviderCLIConfig(
                name: "abacusai",
                aliases: ["abacus-ai"],
                versionDetector: nil))
    }
}

// MARK: - Fetch Strategy

struct AbacusWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "abacus.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        context.settings?.abacus?.cookieSource != .off
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let manual: String?
        if context.settings?.abacus?.cookieSource == .manual {
            guard let header = Self.manualCookieHeader(from: context) else {
                throw AbacusUsageError.noSessionCookie
            }
            manual = header
        } else {
            manual = nil
        }
        let logger: ((String) -> Void)? = context.verbose
            ? { msg in CodexBarLog.logger(LogCategories.provider(.abacus, scope: "usage")).verbose(msg) }
            : nil
        let snap = try await AbacusUsageFetcher.fetchUsage(
            cookieHeaderOverride: manual,
            browserDetection: context.browserDetection,
            timeout: context.webTimeout,
            logger: logger)
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: "web")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func manualCookieHeader(from context: ProviderFetchContext) -> String? {
        guard context.settings?.abacus?.cookieSource == .manual else { return nil }
        return CookieHeaderNormalizer.normalize(context.settings?.abacus?.manualCookieHeader)
    }
}
