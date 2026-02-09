import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum FactoryProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .factory,
            metadata: ProviderMetadata(
                id: .factory,
                displayName: "Droid",
                sessionLabel: "Standard",
                weeklyLabel: "Premium",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Droid usage",
                cliName: "factory",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://app.factory.ai/settings/billing",
                statusPageURL: "https://status.factory.ai",
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .factory,
                iconResourceName: "ProviderIcon-factory",
                color: ProviderColor(red: 255 / 255, green: 107 / 255, blue: 53 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Droid cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [FactoryStatusFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "factory",
                versionDetector: nil))
    }
}

struct FactoryStatusFetchStrategy: ProviderFetchStrategy {
    let id: String = "factory.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.factory?.cookieSource != .off else { return false }
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = FactoryStatusProbe(browserDetection: context.browserDetection)
        let manual = Self.manualCookieHeader(from: context)
        let logger = CodexBarLog.logger(LogCategories.factory)
        let snap = try await probe.fetch(cookieHeaderOverride: manual) { message in
            // Avoid coupling the probe to our logging API; keep it a string-based callback.
            logger.debug(message)
        }
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: "web")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func manualCookieHeader(from context: ProviderFetchContext) -> String? {
        guard context.settings?.factory?.cookieSource == .manual else { return nil }
        return CookieHeaderNormalizer.normalize(context.settings?.factory?.manualCookieHeader)
    }
}
