import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum T3ChatProviderDescriptor {
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
                iconStyle: .codex,
                iconResourceName: "ProviderIcon-t3chat",
                color: ProviderColor(red: 245 / 255, green: 102 / 255, blue: 71 / 255)),
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
        guard context.settings?.t3chat?.cookieSource != .off else { return false }
        return true
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
        return CookieHeaderNormalizer.normalize(context.settings?.t3chat?.manualCookieHeader)
    }
}
