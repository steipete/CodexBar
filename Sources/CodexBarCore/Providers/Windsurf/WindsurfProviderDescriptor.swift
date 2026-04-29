import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum WindsurfProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .windsurf,
            metadata: ProviderMetadata(
                id: .windsurf,
                displayName: "Windsurf",
                sessionLabel: "Daily",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Windsurf usage",
                cliName: "windsurf",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://windsurf.com/subscription/usage",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .windsurf,
                iconResourceName: "ProviderIcon-windsurf",
                color: ProviderColor(red: 52 / 255, green: 232 / 255, blue: 187 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Windsurf cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web, .cli],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                    [WindsurfWebFetchStrategy(), WindsurfLocalFetchStrategy()]
                })),
            cli: ProviderCLIConfig(
                name: "windsurf",
                versionDetector: nil))
    }
}

struct WindsurfWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "windsurf.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.sourceMode.usesWeb else { return false }
        guard context.settings?.windsurf?.cookieSource != .off else { return false }
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        #if os(macOS)
        let cookieSource = context.settings?.windsurf?.cookieSource ?? .auto
        let manualToken = Self.manualToken(from: context)
        let usage = try await WindsurfWebFetcher.fetchUsage(
            browserDetection: context.browserDetection,
            cookieSource: cookieSource,
            manualSessionInput: manualToken,
            timeout: context.webTimeout,
            logger: context.verbose ? { print($0) } : nil)
        return self.makeResult(usage: usage, sourceLabel: "windsurf-web")
        #else
        throw WindsurfStatusProbeError.notSupported
        #endif
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto
    }

    private static func manualToken(from context: ProviderFetchContext) -> String? {
        guard context.settings?.windsurf?.cookieSource == .manual else { return nil }
        let header = context.settings?.windsurf?.manualCookieHeader ?? ""
        return header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : header
    }
}

struct WindsurfLocalFetchStrategy: ProviderFetchStrategy {
    let id: String = "windsurf.local"
    let kind: ProviderFetchKind = .localProbe

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        context.sourceMode != .web
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = WindsurfStatusProbe()
        let planInfo = try probe.fetch()
        let usage = planInfo.toUsageSnapshot()
        return self.makeResult(
            usage: usage,
            sourceLabel: "local")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
