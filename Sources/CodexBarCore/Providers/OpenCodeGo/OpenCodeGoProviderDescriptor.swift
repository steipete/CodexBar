import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum OpenCodeGoProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .opencodego,
            metadata: ProviderMetadata(
                id: .opencodego,
                displayName: "OpenCode Go",
                sessionLabel: "5-hour",
                weeklyLabel: "Weekly",
                opusLabel: "Monthly",
                supportsOpus: true,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show OpenCode Go usage",
                cliName: "opencodego",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://opencode.ai",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .opencodego,
                iconResourceName: "ProviderIcon-opencodego",
                color: ProviderColor(red: 59 / 255, green: 130 / 255, blue: 246 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "OpenCode Go cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "opencodego",
                versionDetector: nil))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        if context.sourceMode == .web {
            return [OpenCodeGoUsageFetchStrategy()]
        }
        return [
            OpenCodeGoUsageFetchStrategy(),
            OpenCodeGoLocalUsageFetchStrategy(),
        ]
    }
}

struct OpenCodeGoLocalUsageFetchStrategy: ProviderFetchStrategy {
    let id: String = "opencodego.local"
    let kind: ProviderFetchKind = .localProbe

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let snapshot = try await self.snapshot(context: context)
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: "local")
    }

    func shouldFallback(on error: Error, context _: ProviderFetchContext) -> Bool {
        error is OpenCodeGoLocalUsageError
    }

    private func snapshot(context: ProviderFetchContext) async throws -> OpenCodeGoUsageSnapshot {
        let snapshot = try OpenCodeGoLocalUsageReader().fetch()
        guard context.includeOptionalUsage,
              context.settings?.opencodego?.cookieSource != .off
        else {
            return snapshot
        }

        guard let cookieHeader = Self.cachedOrManualCookieHeader(context: context) else {
            return snapshot
        }

        let workspaceOverride = context.settings?.opencodego?.workspaceID
            ?? context.env["CODEXBAR_OPENCODEGO_WORKSPACE_ID"]
        let zenBalanceTask = Task<Double?, Error> {
            do {
                return try await OpenCodeGoUsageFetcher.fetchOptionalZenBalance(
                    cookieHeader: cookieHeader,
                    timeout: context.webTimeout,
                    workspaceIDOverride: workspaceOverride)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return nil
            }
        }
        let zenBalance = try await OpenCodeGoUsageFetcher.completedOptionalZenBalance(from: zenBalanceTask)
        return snapshot.withZenBalanceUSD(zenBalance)
    }

    private static func cachedOrManualCookieHeader(context: ProviderFetchContext) -> String? {
        if let settings = context.settings?.opencodego, settings.cookieSource == .manual {
            return OpenCodeWebCookieSupport.requestCookieHeader(from: settings.manualCookieHeader)
        }

        #if os(macOS)
        guard let cached = CookieHeaderCache.load(provider: .opencodego) else { return nil }
        return OpenCodeWebCookieSupport.requestCookieHeader(from: cached.cookieHeader)
        #else
        return nil
        #endif
    }
}

struct OpenCodeGoUsageFetchStrategy: ProviderFetchStrategy {
    let id: String = "opencodego.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.opencodego?.cookieSource != .off else { return false }
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let workspaceOverride = context.settings?.opencodego?.workspaceID
            ?? context.env["CODEXBAR_OPENCODEGO_WORKSPACE_ID"]
        let cookieSource = context.settings?.opencodego?.cookieSource ?? .auto
        do {
            let cookieHeader = try Self.resolveCookieHeader(context: context, allowCached: true)
            let snapshot = try await OpenCodeGoUsageFetcher.fetchUsage(
                cookieHeader: cookieHeader,
                timeout: context.webTimeout,
                workspaceIDOverride: workspaceOverride,
                includeZenBalance: context.includeOptionalUsage)
            return self.makeResult(
                usage: snapshot.toUsageSnapshot(),
                sourceLabel: "web")
        } catch OpenCodeGoUsageError.invalidCredentials where cookieSource != .manual {
            #if os(macOS)
            CookieHeaderCache.clear(provider: .opencodego)
            let cookieHeader = try Self.resolveCookieHeader(context: context, allowCached: false)
            let snapshot = try await OpenCodeGoUsageFetcher.fetchUsage(
                cookieHeader: cookieHeader,
                timeout: context.webTimeout,
                workspaceIDOverride: workspaceOverride,
                includeZenBalance: context.includeOptionalUsage)
            return self.makeResult(
                usage: snapshot.toUsageSnapshot(),
                sourceLabel: "web")
            #else
            throw OpenCodeGoUsageError.invalidCredentials
            #endif
        }
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        guard context.sourceMode == .auto else { return false }
        return switch error {
        case OpenCodeGoSettingsError.missingCookie,
             OpenCodeGoSettingsError.invalidCookie,
             OpenCodeGoUsageError.invalidCredentials:
            true
        default:
            false
        }
    }

    static func resolveCookieHeader(context: ProviderFetchContext, allowCached: Bool) throws -> String {
        try OpenCodeWebCookieSupport.resolveCookieHeader(
            context: OpenCodeWebCookieSupport.Context(
                settings: context.settings?.opencodego,
                provider: .opencodego,
                browserDetection: context.browserDetection,
                allowCached: allowCached),
            invalidCookie: OpenCodeGoSettingsError.invalidCookie,
            missingCookie: OpenCodeGoSettingsError.missingCookie)
    }
}

enum OpenCodeGoSettingsError: LocalizedError {
    case missingCookie
    case invalidCookie

    var errorDescription: String? {
        switch self {
        case .missingCookie:
            "No OpenCode Go session cookies found in browsers."
        case .invalidCookie:
            "OpenCode Go cookie header is invalid."
        }
    }
}
