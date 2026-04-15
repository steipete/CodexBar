import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum RovoDevProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .rovodev,
            metadata: ProviderMetadata(
                id: .rovodev,
                displayName: "Rovo Dev",
                sessionLabel: "Monthly credits",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Rovo Dev usage",
                cliName: "rovodev",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: nil,
                statusPageURL: nil,
                statusLinkURL: (try? RovoDevACLIConfig.load()).map { "https://\($0.site)/rovodev/your-usage" } ?? "https://atlassian.net/rovodev/your-usage"),
            branding: ProviderBranding(
                iconStyle: .rovodev,
                iconResourceName: "ProviderIcon-rovodev",
                color: ProviderColor(red: 0 / 255, green: 101 / 255, blue: 255 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Rovo Dev cost tracking is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [RovoDevWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "rovodev",
                versionDetector: nil))
    }
}

struct RovoDevWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "rovodev.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.rovodev?.cookieSource != .off else { return false }
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let fetcher = RovoDevUsageFetcher(browserDetection: context.browserDetection)
        let manual = context.settings?.rovodev?.cookieSource == .manual
            ? CookieHeaderNormalizer.normalize(context.settings?.rovodev?.manualCookieHeader)
            : nil
        let isManualMode = context.settings?.rovodev?.cookieSource == .manual
        let logger: ((String) -> Void)? = context.verbose
            ? { msg in CodexBarLog.logger(LogCategories.rovodev).verbose(msg) }
            : nil
        let snap = try await fetcher.fetch(
            cookieHeaderOverride: manual,
            manualCookieMode: isManualMode,
            logger: logger)
        return self.makeResult(usage: snap.toUsageSnapshot(), sourceLabel: "web")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
