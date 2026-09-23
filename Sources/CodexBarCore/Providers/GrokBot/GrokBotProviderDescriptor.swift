import Foundation
import SweetCookieKit

public enum GrokBotProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(tokenAccountSupport: TokenAccountSupport(
        title: "Session tokens",
        subtitle: "Store multiple Cursor Cookie headers for Grok Bot.",
        placeholder: "Cookie: …",
        injection: .cookieHeader,
        requiresManualCookieSource: true,
        cookieName: nil,
        selectedAccountRequiresManualCookieSource: true))

    /// Grok Bot allowance is tied to the same cursor.com session as Cursor usage.
    private static var browserCookieOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.safari] + Browser.defaultImportOrder.filter { $0 != .safari }
        #else
        nil
        #endif
    }

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .grokbot,
            settingsSection: .init(GrokBotProviderSettingsKey.self, cookieSettings: GrokBotProviderSettings.self),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .grokbot,
                displayName: "Grok Bot",
                sessionLabel: "Weekly",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Grok Bot usage",
                cliName: "grokbot",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                sharePlanLabels: [
                    "trial": "Grok Bot Trial",
                    "grok bot trial": "Grok Bot Trial",
                ],
                browserCookieOrder: self.browserCookieOrder
                    ?? ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://cursor.com/dashboard?tab=usage",
                statusPageURL: "https://status.cursor.com",
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .grokbot),
                iconResourceName: "ProviderIcon-grokbot",
                color: ProviderColor(red: 0 / 255, green: 0 / 255, blue: 0 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x000000),
                    ProviderColor(hex: 0xFFFFFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Grok Bot cost history is not available." }),
            pace: ProviderPaceCapability(resetWindowPace: .windowDurationPresent),
            presentation: ProviderUsagePresentation(
                menuCard: ProviderMenuCardPresentation(primaryDetailKind: .requestQuota)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [GrokBotWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "grokbot",
                aliases: ["grok-bot"],
                versionDetector: nil,
                browserSupportExemption: { sourceMode, _, settings in
                    #if os(Linux)
                    guard settings?.grokbot?.cookieSource != .off else { return false }
                    if settings?.grokbot?.cookieSource == .manual {
                        return CookieHeaderNormalizer.normalize(settings?.grokbot?.manualCookieHeader) != nil
                    }
                    return sourceMode == .auto || sourceMode == .cli
                    #else
                    false
                    #endif
                }))
    }
}

struct GrokBotWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "grokbot.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        #if os(macOS) || os(Linux)
        guard context.settings?.grokbot?.cookieSource != .off else { return false }
        return true
        #else
        false
        #endif
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        #if os(macOS) || os(Linux)
        let probe = CursorStatusProbe(
            browserDetection: context.browserDetection,
            sessionCacheProvider: .grokbot)
        let manual = Self.manualCookieHeader(from: context)
        let logger: ((String) -> Void)? = context.verbose
            ? { message in CodexBarLog.logger(LogCategories.provider(.grokbot)).verbose(message) }
            : nil
        let usage = try await probe.fetchGrokBotUsage(
            cookieHeaderOverride: manual,
            allowAppAuthFallback: context.sourceMode != .web,
            logger: logger)
        return self.makeResult(usage: usage, sourceLabel: "web")
        #else
        throw GrokBotProbeError.notSupported
        #endif
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func manualCookieHeader(from context: ProviderFetchContext) -> String? {
        guard context.settings?.grokbot?.cookieSource == .manual else { return nil }
        return CookieHeaderNormalizer.normalize(context.settings?.grokbot?.manualCookieHeader)
    }
}
