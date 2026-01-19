import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum AmpProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .amp,
            metadata: ProviderMetadata(
                id: .amp,
                displayName: "Amp",
                sessionLabel: "Amp Free",
                weeklyLabel: "Balance",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Amp usage",
                cliName: "amp",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://ampcode.com/settings",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .amp,
                iconResourceName: "ProviderIcon-amp",
                color: ProviderColor(red: 220 / 255, green: 38 / 255, blue: 38 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Amp cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [AmpStatusFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "amp",
                versionDetector: nil))
    }
}

struct AmpStatusFetchStrategy: ProviderFetchStrategy {
    let id: String = "amp.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.amp?.cookieSource != .off else { return false }
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let fetcher = AmpUsageFetcher(browserDetection: context.browserDetection)
        let manual = Self.manualCookieHeader(from: context)
        let logger: ((String) -> Void)? = context.verbose ? { msg in print("[amp] \(msg)") } : nil
        let snap = try await fetcher.fetch(cookieHeaderOverride: manual, logger: logger)
        return self.makeResult(
            usage: snap.toUsageSnapshot(now: snap.updatedAt),
            sourceLabel: "web")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func manualCookieHeader(from context: ProviderFetchContext) -> String? {
        guard context.settings?.amp?.cookieSource == .manual else { return nil }
        return CookieHeaderNormalizer.normalize(context.settings?.amp?.manualCookieHeader)
    }
}
