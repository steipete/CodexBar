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
                supportsCredits: false,
                creditsHint: "",
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
            ? { msg in CodexBarLog.logger(LogCategories.abacusUsage).verbose(msg) }
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
