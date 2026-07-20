import Foundation

public enum T3ChatProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .t3chat,
            metadata: ProviderMetadata(
                id: .t3chat,
                displayName: "T3 Chat",
                sessionLabel: "Base",
                weeklyLabel: "Overage",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show T3 Chat usage",
                cliName: "t3chat",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://t3.chat/settings/customization",
                subscriptionDashboardURL: "https://t3.chat/settings/subscription",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .t3chat,
                iconResourceName: "ProviderIcon-t3chat",
                color: ProviderColor(red: 245 / 255, green: 102 / 255, blue: 71 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x970B72),
                    ProviderColor(hex: 0xE6229C),
                    ProviderColor(hex: 0xFEA0F6),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "T3 Chat cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [T3ChatWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "t3chat",
                aliases: ["t3-chat", "t3"],
                versionDetector: nil))
    }
}

struct T3ChatWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "t3chat.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        let cookieSource = context.settings?.t3chat?.cookieSource ?? .auto
        guard cookieSource != .off else { return false }
        if cookieSource == .manual {
            return T3ChatUsageFetcher.requestContext(from: context.settings?.t3chat?.manualCookieHeader) != nil
        }
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let fetcher = T3ChatUsageFetcher(browserDetection: context.browserDetection)
        let manual = Self.manualCookieHeader(from: context)
        let logger: ((String) -> Void)? = context.verbose
            ? { msg in CodexBarLog.logger(LogCategories.t3chat).verbose(msg) }
            : nil
        let snapshot = try await fetcher.fetch(
            cookieHeaderOverride: manual,
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
        guard context.settings?.t3chat?.cookieSource == .manual else { return nil }
        return context.settings?.t3chat?.manualCookieHeader
    }
}
