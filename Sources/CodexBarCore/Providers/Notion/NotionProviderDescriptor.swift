import Foundation
import SweetCookieKit

public enum NotionProviderDescriptor {
    /// Notion reports the rolling allowance as a `6h` window — session-shaped, but wider than the
    /// 5-hour ceiling the shared session-pace paths assume. Windows longer than this are not rolling
    /// allowances and must not be paced as one.
    public static let rollingWindowMaxMinutes = 6 * 60

    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    private static var browserCookieOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.chrome]
        #else
        nil
        #endif
    }

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .notion,
            settingsSection: .init(
                NotionProviderSettingsKey.self,
                cookieSettings: { settings in
                    CookieProviderSettings(
                        cookieSource: settings.cookieSource,
                        manualCookieHeader: settings.manualCookieHeader)
                },
                credentialSettings: { context in
                    let settings = context.cookieSettings(for: .notion)
                    return NotionProviderSettings(
                        cookieSource: settings.cookieSource,
                        manualCookieHeader: settings.manualCookieHeader,
                        workspaceID: context.config?.workspaceID)
                }),
            metadata: ProviderMetadata(
                id: .notion,
                displayName: "Notion AI",
                sessionLabel: "Rolling",
                weeklyLabel: "Monthly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Notion AI usage",
                cliName: "notion",
                defaultEnabled: false,
                // Not yet supported in widgets.
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                sharePlanLabels: ["free": "Free", "plus": "Plus", "business": "Business", "enterprise": "Enterprise"],
                browserCookieOrder: self.browserCookieOrder,
                dashboardURL: "https://app.notion.com/",
                statusPageURL: nil,
                statusLinkURL: "https://status.notion.so/"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .notion),
                iconResourceName: "ProviderIcon-notion",
                // Notion's UI accent blue, not its near-black brand ink: the ink is
                // indistinguishable from the unfilled track in a usage gauge.
                color: ProviderColor(red: 51 / 255, green: 126 / 255, blue: 169 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x337EA9),
                    ProviderColor(hex: 0xE16259),
                    ProviderColor(hex: 0x37352F),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Notion AI cost summary is not supported." }),
            // The billing-period window renews on a calendar cycle, so pace has to measure the real
            // month ending at the reset rather than the 30-day sentinel the snapshot carries.
            pace: ProviderPaceCapability(
                resetWindowPace: .windowDuration(minutes: ProviderPaceCapability.monthlyWindowSentinelMinutes),
                inferredMonthlyDuration: .windowDuration(
                    minutes: ProviderPaceCapability.monthlyWindowSentinelMinutes),
                primary: .session(maximumMinutes: self.rollingWindowMaxMinutes),
                sessionPaceWindowRule: .custom { window, _ in
                    guard let minutes = window.windowMinutes else { return false }
                    return minutes <= Self.rollingWindowMaxMinutes
                }),
            presentation: ProviderUsagePresentation(
                semanticWindowResolver: { snapshot in
                    let rolling = snapshot.primary.flatMap { window -> RateWindow? in
                        guard !window.isSyntheticPlaceholder,
                              let minutes = window.windowMinutes,
                              minutes <= Self.rollingWindowMaxMinutes
                        else { return nil }
                        return window
                    }
                    let monthly = snapshot.secondary.flatMap { window -> RateWindow? in
                        guard !window.isSyntheticPlaceholder,
                              window.windowMinutes == ProviderPaceCapability.monthlyWindowSentinelMinutes
                        else { return nil }
                        return window
                    }
                    return ProviderSemanticWindows(session: rolling, weekly: monthly)
                },
                menuBarLayoutSecondaryLabel: "Monthly"),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [NotionWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "notion",
                aliases: ["notion-ai", "notionai"],
                versionDetector: nil))
    }
}

struct NotionWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "notion.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        let cookieSource = context.settings?.notion?.cookieSource ?? .auto
        guard cookieSource != .off else { return false }
        if cookieSource == .manual {
            return NotionUsageFetcher.requestContext(from: context.settings?.notion?.manualCookieHeader) != nil
        }
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let fetcher = NotionUsageFetcher(browserDetection: context.browserDetection)
        let manual = Self.manualCookieHeader(from: context)
        let logger: ((String) -> Void)? = context.verbose
            ? { msg in CodexBarLog.logger(LogCategories.provider(.notion)).verbose(msg) }
            : nil
        let snapshot = try await fetcher.fetch(
            cookieHeaderOverride: manual,
            preferredSpaceID: context.settings?.notion?.workspaceID,
            timeout: context.webTimeout,
            logger: logger)
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: "web")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func manualCookieHeader(from context: ProviderFetchContext) -> String? {
        guard context.settings?.notion?.cookieSource == .manual else { return nil }
        return context.settings?.notion?.manualCookieHeader
    }
}
