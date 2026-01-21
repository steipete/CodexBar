import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum CursorProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .cursor,
            metadata: ProviderMetadata(
                id: .cursor,
                displayName: "Cursor",
                sessionLabel: "Plan",
                weeklyLabel: "On-Demand",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: true,
                creditsHint: "On-demand usage beyond included plan limits.",
                toggleTitle: "Show Cursor usage",
                cliName: "cursor",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://cursor.com/dashboard?tab=usage",
                statusPageURL: "https://status.cursor.com",
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .cursor,
                iconResourceName: "ProviderIcon-cursor",
                color: ProviderColor(red: 0 / 255, green: 191 / 255, blue: 165 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Cursor cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [CursorStatusFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "cursor",
                versionDetector: nil))
    }
}

struct CursorStatusFetchStrategy: ProviderFetchStrategy {
    let id: String = "cursor.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.cursor?.cookieSource != .off else { return false }
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = CursorStatusProbe(browserDetection: context.browserDetection)
        let manual = Self.manualCookieHeader(from: context)
        let snap = try await probe.fetch(cookieHeaderOverride: manual)
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: "web")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func manualCookieHeader(from context: ProviderFetchContext) -> String? {
        guard context.settings?.cursor?.cookieSource == .manual else { return nil }
        return CookieHeaderNormalizer.normalize(context.settings?.cursor?.manualCookieHeader)
    }
}
