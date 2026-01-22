import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum WindsurfProviderDescriptor {
    public static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .windsurf,
            metadata: ProviderMetadata(
                id: .windsurf,
                displayName: "Windsurf",
                sessionLabel: "Credits",
                weeklyLabel: "Usage",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: true,
                creditsHint: "Prompt credits used this billing cycle.",
                toggleTitle: "Show Windsurf usage",
                cliName: "windsurf",
                defaultEnabled: false,
                browserCookieOrder: .safariChromeFirefox,
                dashboardURL: "https://windsurf.com/subscription/usage",
                statusPageURL: nil,
                statusLinkURL: "https://status.codeium.com"),
            branding: ProviderBranding(
                iconStyle: .windsurf,
                iconResourceName: "ProviderIcon-windsurf",
                color: ProviderColor(red: 0.1, green: 0.7, blue: 1.0)), // Use a nice Windsurf blue
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Windsurf cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web, .cli], // Windsurf supports web and CLI extraction
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [WindsurfStatusFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "windsurf",
                versionDetector: nil))
    }
}

struct WindsurfStatusFetchStrategy: ProviderFetchStrategy {
    let id: String = "windsurf.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.windsurf?.cookieSource != .off else { return false }
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = WindsurfStatusProbe()
        // WindsurfStatusProbe.fetch now handles bearer tokens and browser cookies internally
        let snap = try await probe.fetch()
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: "web")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func manualCookieHeader(from context: ProviderFetchContext) -> String? {
        guard context.settings?.windsurf?.cookieSource == .manual else { return nil }
        return CookieHeaderNormalizer.normalize(context.settings?.windsurf?.manualCookieHeader)
    }
}
