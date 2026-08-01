import Foundation

public enum NotionProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .notion,
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
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
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
            ? { msg in CodexBarLog.logger(LogCategories.notion).verbose(msg) }
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
