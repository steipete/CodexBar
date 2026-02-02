import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum TraeProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .trae,
            metadata: ProviderMetadata(
                id: .trae,
                displayName: "Trae",
                sessionLabel: "Pro Plan",
                weeklyLabel: "Extra Package",
                opusLabel: "Extra Package",
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Trae usage",
                cliName: "trae",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://www.trae.ai/account-setting",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .trae,
                iconResourceName: "ProviderIcon-trae",
                color: ProviderColor(red: 59 / 255, green: 130 / 255, blue: 246 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Trae cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [TraeStatusFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "trae",
                versionDetector: nil))
    }
}

struct TraeStatusFetchStrategy: ProviderFetchStrategy {
    let id: String = "trae.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.trae?.cookieSource != .off else { return false }
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let fetcher = TraeUsageFetcher(browserDetection: context.browserDetection)
        let manual = Self.manualJWTToken(from: context)
        let logger: ((String) -> Void)? = context.verbose
            ? { msg in CodexBarLog.logger(LogCategories.trae).verbose(msg) }
            : nil
        let snap = try await fetcher.fetch(jwtOverride: manual, logger: logger)
        return self.makeResult(
            usage: snap.toUsageSnapshot(now: snap.updatedAt),
            sourceLabel: "web")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func manualJWTToken(from context: ProviderFetchContext) -> String? {
        guard context.settings?.trae?.cookieSource == .manual else { return nil }
        // For JWT tokens, don't use CookieHeaderNormalizer as it expects cookie format (name=value pairs)
        // Just return the raw value directly
        return context.settings?.trae?.manualCookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
