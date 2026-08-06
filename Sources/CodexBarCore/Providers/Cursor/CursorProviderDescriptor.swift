import Foundation
import SweetCookieKit

public enum CursorProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(tokenAccountSupport: TokenAccountSupport(
        title: "Session tokens",
        subtitle: "Store multiple Cursor Cookie headers.",
        placeholder: "Cookie: …",
        injection: .cookieHeader,
        requiresManualCookieSource: true,
        cookieName: nil,
        selectedAccountRequiresManualCookieSource: true))

    /// Active Cursor sessions often live only in Safari; Chromium profiles may carry stale tokens.
    private static var browserCookieOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.safari] + Browser.defaultImportOrder.filter { $0 != .safari }
        #else
        nil
        #endif
    }

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .cursor,
            menuBarMetrics: ProviderMenuBarMetricCapabilities(
                supported: [.automatic, .primary, .secondary, .tertiary, .extraUsage],
                tertiaryRequiresWindow: true),
            settingsSection: .init(CursorProviderSettingsKey.self, cookieSettings: CursorProviderSettings.self),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .cursor,
                displayName: "Cursor",
                sessionLabel: "Total",
                weeklyLabel: "Auto",
                opusLabel: "API",
                supportsOpus: true,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Cursor usage",
                cliName: "cursor",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                sharePlanLabels: [
                    "free": "Cursor Free", "cursor free": "Cursor Free",
                    "hobby": "Cursor Hobby", "cursor hobby": "Cursor Hobby",
                    "pro": "Cursor Pro", "cursor pro": "Cursor Pro",
                    "team": "Cursor Team", "cursor team": "Cursor Team",
                    "business": "Cursor Business", "cursor business": "Cursor Business",
                    "enterprise": "Cursor Enterprise", "cursor enterprise": "Cursor Enterprise",
                    "ultra": "Cursor Ultra", "cursor ultra": "Cursor Ultra",
                ],
                debugPane: ProviderDebugPaneCapabilities(probeLogOrder: 2),
                browserCookieOrder: self.browserCookieOrder
                    ?? ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://cursor.com/dashboard?tab=usage",
                statusPageURL: "https://status.cursor.com",
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .cursor),
                iconResourceName: "ProviderIcon-cursor",
                color: ProviderColor(red: 0 / 255, green: 191 / 255, blue: 165 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x1B1913),
                    ProviderColor(hex: 0xEDECEC),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "No Cursor cost usage found. Sign in to Cursor in your browser or the Cursor app." },
                menuHintLines: [.estimate],
                supportsTokenSnapshot: self.supportsTokenSnapshot,
                estimateDisclaimer: "From Cursor's usage dashboard at vendor token rates; may differ from your " +
                    "invoice."),
            pace: ProviderPaceCapability(resetWindowPace: .windowDurationPresent),
            presentation: ProviderUsagePresentation(
                requestedMenuBarLaneOrders: [
                    .tertiary: [.tertiary, .secondary, .primary],
                ],
                automaticSelectionPrioritizesExhaustedWindow: false,
                menuBarWindowResolver: self.menuBarWindow,
                menuCard: ProviderMenuCardPresentation(
                    costVisibilityResolver: { $0.showOptionalUsage },
                    supportsInlineTokenCostDashboard: true,
                    primaryDetailKind: .requestQuota)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [CursorStatusFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "cursor",
                versionDetector: nil,
                supportsCostCommand: self.supportsCostCommand,
                browserSupportExemption: { _, _, settings in
                    #if os(Linux)
                    // Linux uses Cursor app auth and manual cookies; browser import remains macOS-only.
                    settings?.cursor?.cookieSource != .off
                    #else
                    false
                    #endif
                }))
    }

    private static var supportsCostCommand: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    private static func menuBarWindow(
        context: ProviderMenuBarWindowContext) -> ProviderMenuBarWindowResolution
    {
        guard context.metric == .automatic else { return .unhandled }
        let total = context.snapshot.primary
        let subquotas = [context.snapshot.secondary, context.snapshot.tertiary].compactMap(\.self)
        let usableSubquotas = subquotas.filter { $0.remainingPercent > 0 }
        if let total, total.remainingPercent <= 0 {
            return .resolved(total)
        }
        if !subquotas.isEmpty, usableSubquotas.isEmpty {
            return .resolved(subquotas.max(by: { $0.usedPercent < $1.usedPercent }))
        }
        return .resolved(([total].compactMap(\.self) + usableSubquotas)
            .max(by: { $0.usedPercent < $1.usedPercent }))
    }

    private static var supportsTokenSnapshot: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
}

struct CursorStatusFetchStrategy: ProviderFetchStrategy {
    let id: String = "cursor.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.cursor?.cookieSource != .off else { return false }
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = CursorStatusProbe(browserDetection: context.browserDetection)
        let manual = Self.manualCookieHeader(from: context)
        let snap = try await probe.fetch(cookieHeaderOverride: manual)
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: "web")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func manualCookieHeader(from context: ProviderFetchContext) -> String? {
        guard context.settings?.cursor?.cookieSource == .manual else { return nil }
        return CookieHeaderNormalizer.normalize(context.settings?.cursor?.manualCookieHeader)
    }
}
