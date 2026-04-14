import CodexBarMacroSupport
import Foundation

#if os(macOS)
import SweetCookieKit
#endif

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum AbacusProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .abacus,
            metadata: ProviderMetadata(
                id: .abacus,
                displayName: "Abacus AI",
                sessionLabel: "Credits",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: true,
                creditsHint: "Abacus AI compute credits for ChatLLM/RouteLLM usage.",
                toggleTitle: "Show Abacus AI usage",
                cliName: "abacusai",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://apps.abacus.ai/chatllm/admin/compute-points-usage",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .abacus,
                iconResourceName: "ProviderIcon-abacus",
                color: ProviderColor(red: 56 / 255, green: 189 / 255, blue: 248 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Abacus AI cost summary is not supported." }),
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
        guard context.settings?.abacus?.cookieSource != .off else { return false }
        if context.settings?.abacus?.cookieSource == .manual {
            return CookieHeaderNormalizer.normalize(context.settings?.abacus?.manualCookieHeader) != nil
        }
        if CookieHeaderCache.load(provider: .abacus) != nil { return true }
        #if os(macOS)
        // Try Chrome first, then any installed browser as fallback.
        if AbacusCookieImporter.hasSession(browserDetection: context.browserDetection) {
            return true
        }
        return AbacusCookieImporter.hasSession(
            browserDetection: context.browserDetection,
            preferredBrowsers: [])
        #else
        return false
        #endif
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let manual = Self.manualCookieHeader(from: context)
        let logger: ((String) -> Void)? = context.verbose
            ? { msg in CodexBarLog.logger(LogCategories.abacusUsage).verbose(msg) }
            : nil
        let snap = try await AbacusUsageFetcher.fetchUsage(cookieHeaderOverride: manual, logger: logger)
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
