import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum OpenCodeProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .opencode,
            metadata: ProviderMetadata(
                id: .opencode,
                displayName: "OpenCode",
                sessionLabel: "5-hour",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show OpenCode usage",
                cliName: "opencode",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://opencode.ai",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .opencode,
                iconResourceName: "ProviderIcon-opencode",
                color: ProviderColor(red: 59 / 255, green: 130 / 255, blue: 246 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "OpenCode cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [OpenCodeUsageFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "opencode",
                versionDetector: nil))
    }
}

struct OpenCodeUsageFetchStrategy: ProviderFetchStrategy {
    let id: String = "opencode.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.opencode?.cookieSource != .off else { return false }
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let workspaceOverride = context.settings?.opencode?.workspaceID
            ?? context.env["CODEXBAR_OPENCODE_WORKSPACE_ID"]
        let cookieSource = context.settings?.opencode?.cookieSource ?? .auto
        do {
            let cookieHeader = try Self.resolveCookieHeader(context: context, allowCached: true)
            let snapshot = try await OpenCodeUsageFetcher.fetchUsage(
                cookieHeader: cookieHeader,
                timeout: context.webTimeout,
                workspaceIDOverride: workspaceOverride)
            return self.makeResult(
                usage: snapshot.toUsageSnapshot(),
                sourceLabel: "web")
        } catch OpenCodeUsageError.invalidCredentials where cookieSource != .manual {
            #if os(macOS)
            CookieHeaderCache.clear(provider: .opencode)
            let cookieHeader = try Self.resolveCookieHeader(context: context, allowCached: false)
            let snapshot = try await OpenCodeUsageFetcher.fetchUsage(
                cookieHeader: cookieHeader,
                timeout: context.webTimeout,
                workspaceIDOverride: workspaceOverride)
            return self.makeResult(
                usage: snapshot.toUsageSnapshot(),
                sourceLabel: "web")
            #else
            throw OpenCodeUsageError.invalidCredentials
            #endif
        }
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func resolveCookieHeader(context: ProviderFetchContext, allowCached: Bool) throws -> String {
        try OpenCodeWebCookieSupport.resolveCookieHeader(
            context: OpenCodeWebCookieSupport.Context(
                settings: context.settings?.opencode,
                provider: .opencode,
                browserDetection: context.browserDetection,
                allowCached: allowCached),
            invalidCookie: OpenCodeSettingsError.invalidCookie,
            missingCookie: OpenCodeSettingsError.missingCookie)
    }
}

enum OpenCodeSettingsError: LocalizedError {
    case missingCookie
    case invalidCookie

    var errorDescription: String? {
        switch self {
        case .missingCookie:
            "No OpenCode session cookies found in browsers."
        case .invalidCookie:
            "OpenCode cookie header is invalid."
        }
    }
}
