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
                tertiaryRequiresWindow: true,
                namedExtras: [CursorSandUsageStatus.extraWindowID: CursorSandUsageStatus.extraWindowTitle],
                // Several Cursor pools fit in the menu bar only with short tags; Total and Third Party
                // would both derive "T", so the tags are explicit.
                laneShortLabels: [.primary: "T", .secondary: "C", .tertiary: "TP"],
                namedExtraShortLabels: [CursorSandUsageStatus.extraWindowID: "GB"]),
            settingsSection: .init(CursorProviderSettingsKey.self, cookieSettings: CursorProviderSettings.self),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .cursor,
                displayName: "Cursor",
                sessionLabel: "Total",
                weeklyLabel: "Cursor",
                opusLabel: "Third Party",
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
                color: ProviderColor(hex: 0xF54E00),
                confettiPalette: [
                    ProviderColor(hex: 0xF54E00),
                    ProviderColor(hex: 0x1B1913),
                    ProviderColor(hex: 0xEDECEC),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "No Cursor cost usage found. Sign in to Cursor in your browser or the Cursor app." },
                menuHintLines: [.estimate],
                supportsTokenSnapshot: self.supportsCostCommand,
                settingsStatusOrder: 2,
                estimateDisclaimer: "From Cursor's usage dashboard at vendor token rates; may differ from your " +
                    "invoice."),
            pace: ProviderPaceCapability(resetWindowPace: .windowDurationPresent),
            presentation: ProviderUsagePresentation(
                rateWindowLabeler: { metadata, snapshot, _ in
                    ProviderRateWindowLabels(
                        primary: Self.primaryLabel(snapshot: snapshot) ?? metadata.sessionLabel,
                        secondary: Self.primaryLabel(snapshot: snapshot) ?? metadata.weeklyLabel,
                        tertiary: metadata.opusLabel ?? "Sonnet",
                        showsTertiary: metadata.supportsOpus)
                },
                extraRateWindowSelector: { snapshot in
                    (snapshot.extraRateWindows ?? []).filter { $0.id == CursorSandUsageStatus.extraWindowID }
                },
                semanticWindowResolver: self.semanticWindows,
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
                browserSupportExemption: { sourceMode, _, settings in
                    #if os(Linux)
                    guard settings?.cursor?.cookieSource != .off else { return false }
                    if settings?.cursor?.cookieSource == .manual {
                        return CookieHeaderNormalizer.normalize(settings?.cursor?.manualCookieHeader) != nil
                    }
                    // App auth needs no browser integration. Explicit web mode still requires a manual cookie.
                    return sourceMode == .auto || sourceMode == .cli
                    #else
                    false
                    #endif
                }),
            nativeAppBundleIdentifiers: ["com.todesktop.230313mzl4w4u92"])
    }

    private static var supportsCostCommand: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// The X Subscription's shared weekly pool replaces the monthly Total lane as the primary window.
    public static func primaryLabel(snapshot: UsageSnapshot) -> String? {
        self.sharedWeeklyPool(snapshot: snapshot) == nil ? nil : "Weekly"
    }

    /// Monthly Cursor billing cycles never span exactly seven days, so a weekly primary is the shared pool.
    public static func sharedWeeklyPool(snapshot: UsageSnapshot) -> RateWindow? {
        guard let primary = snapshot.primary, primary.windowMinutes == 10080, snapshot.secondary == nil,
              snapshot.detailRow(label: "Request quota") == nil
        else {
            return nil
        }
        return primary
    }

    /// Persisted Grok Bot percentage tokens still name this pool after it becomes primary.
    public static func menuBarExtras(snapshot: UsageSnapshot) -> [NamedRateWindow] {
        guard let window = self.sharedWeeklyPool(snapshot: snapshot) else { return snapshot.extraRateWindows ?? [] }
        return [NamedRateWindow(
            id: CursorSandUsageStatus.extraWindowID, title: CursorSandUsageStatus.extraWindowTitle, window: window)]
    }

    /// Grok Bot is a named extra 7-day allowance. Cursor's monthly Auto bar is the secondary lane
    /// (`weeklyLabel` "Cursor"), so it is the semantic weekly window. The default duration matcher
    /// would pick Grok Bot instead and paint that weekly pace onto Cursor Auto after a billing reset.
    private static func semanticWindows(snapshot: UsageSnapshot) -> ProviderSemanticWindows {
        let weekly = snapshot.secondary.flatMap { window -> RateWindow? in
            guard !window.isSyntheticPlaceholder else { return nil }
            return window
        } ?? Self.sharedWeeklyPool(snapshot: snapshot)
        return ProviderSemanticWindows(session: Self.sharedWeeklyPool(snapshot: snapshot), weekly: weekly)
    }

    private static func menuBarWindow(
        context: ProviderMenuBarWindowContext) -> ProviderMenuBarWindowResolution
    {
        guard context.metric == .automatic else { return .unhandled }
        let total = context.snapshot.primary
        let grokBot = context.snapshot.extraRateWindows?.first {
            $0.id == CursorSandUsageStatus.extraWindowID && $0.usageKnown
        }?.window
        let subquotas = [context.snapshot.secondary, context.snapshot.tertiary, grokBot].compactMap(\.self)
        let usableSubquotas = subquotas.filter { $0.remainingPercent > 0 }
        if let total, total.remainingPercent <= 0 {
            return .resolved(total)
        }
        if !subquotas.isEmpty, usableSubquotas.isEmpty {
            return .resolved(subquotas.max(by: { $0.usedPercent < $1.usedPercent }))
        }
        return .automaticCandidates([total].compactMap(\.self) + usableSubquotas)
    }
}

struct CursorStatusFetchStrategy: ProviderFetchStrategy {
    let id: String = "cursor.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        context.settings?.cursor?.cookieSource != .off
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = CursorStatusProbe(browserDetection: context.browserDetection)
        let manual = context.settings?.cursor?.cookieSource == .manual
            ? CookieHeaderNormalizer.normalize(context.settings?.cursor?.manualCookieHeader) : nil
        let logger: ((String) -> Void)? = context.verbose
            ? { message in CodexBarLog.logger(LogCategories.provider(.cursor)).verbose(message) }
            : nil
        let snap = try await probe.fetch(
            cookieHeaderOverride: manual,
            allowAppAuthFallback: context.sourceMode != .web,
            logger: logger)
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: "web")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
