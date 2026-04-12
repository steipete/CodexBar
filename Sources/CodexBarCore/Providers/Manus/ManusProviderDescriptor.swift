import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum ManusProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .manus,
            metadata: ProviderMetadata(
                id: .manus,
                displayName: "Manus",
                sessionLabel: "Monthly credits",
                weeklyLabel: "Daily refresh",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Manus usage",
                cliName: "manus",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://manus.im",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .manus,
                iconResourceName: "ProviderIcon-manus",
                color: ProviderColor(red: 52 / 255, green: 50 / 255, blue: 45 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Manus cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [ManusWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "manus",
                aliases: [],
                versionDetector: nil))
    }
}

struct ManusWebFetchStrategy: ProviderFetchStrategy {
    private enum SessionTokenSource {
        case manual
        case cache
        case browser
        case environment

        var shouldCacheAfterFetch: Bool {
            self == .browser
        }
    }

    private struct ResolvedSessionToken {
        let value: String
        let source: SessionTokenSource
    }

    let id: String = "manus.web"
    let kind: ProviderFetchKind = .web
    private static let log = CodexBarLog.logger(LogCategories.manusWeb)

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.manus?.cookieSource != .off else { return false }
        if context.settings?.manus?.cookieSource == .manual { return true }

        if let cached = CookieHeaderCache.load(provider: .manus),
           ManusCookieHeader.token(from: cached.cookieHeader) != nil
        {
            return true
        }

        #if os(macOS)
        if ManusCookieImporter.hasSession(browserDetection: context.browserDetection) {
            return true
        }
        #endif

        return ManusSettingsReader.sessionToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let resolvedTokens = try self.resolveSessionTokens(context: context)
        guard !resolvedTokens.isEmpty else {
            throw ManusAPIError.missingToken
        }

        var sawInvalidToken = false
        for resolved in resolvedTokens {
            do {
                let response = try await ManusUsageFetcher.fetchCredits(sessionToken: resolved.value)
                self.cacheTokenIfNeeded(resolved, sourceLabel: "web")
                return self.makeResult(
                    usage: response.toUsageSnapshot(),
                    sourceLabel: "web")
            } catch ManusAPIError.invalidToken {
                sawInvalidToken = true
                if resolved.source == .cache {
                    CookieHeaderCache.clear(provider: .manus)
                }
                continue
            }
        }

        if sawInvalidToken {
            throw ManusAPIError.invalidToken
        }
        throw ManusAPIError.missingToken
    }

    func shouldFallback(on error: Error, context _: ProviderFetchContext) -> Bool {
        if case ManusAPIError.missingToken = error { return false }
        if case ManusAPIError.invalidCookie = error { return false }
        if case ManusAPIError.invalidToken = error { return false }
        return true
    }

    private func resolveSessionTokens(context: ProviderFetchContext) throws -> [ResolvedSessionToken] {
        guard context.settings?.manus?.cookieSource != .off else { return [] }

        if context.settings?.manus?.cookieSource == .manual {
            guard let token = ManusCookieHeader.resolveToken(context: context) else {
                throw ManusAPIError.invalidCookie
            }
            return [ResolvedSessionToken(value: token, source: .manual)]
        }

        var tokens: [ResolvedSessionToken] = []

        if let cached = CookieHeaderCache.load(provider: .manus),
           let token = ManusCookieHeader.token(from: cached.cookieHeader)
        {
            tokens.append(ResolvedSessionToken(value: token, source: .cache))
        }

        tokens.append(contentsOf: self.resolveBrowserOrEnvironmentTokens(context: context))
        return self.deduplicated(tokens)
    }

    private func resolveBrowserOrEnvironmentTokens(context: ProviderFetchContext) -> [ResolvedSessionToken] {
        guard context.settings?.manus?.cookieSource != .off else { return [] }
        var tokens: [ResolvedSessionToken] = []

        #if os(macOS)
        do {
            let sessions = try ManusCookieImporter.importSessions(browserDetection: context.browserDetection)
            tokens.append(contentsOf: sessions.compactMap { session in
                guard let token = session.sessionToken else { return nil }
                return ResolvedSessionToken(value: token, source: .browser)
            })
        } catch {
            Self.log.debug("No Manus browser session available: \(error.localizedDescription)")
        }
        #endif

        if let token = ManusSettingsReader.sessionToken(environment: context.env) {
            tokens.append(ResolvedSessionToken(value: token, source: .environment))
        }
        return self.deduplicated(tokens)
    }

    private func deduplicated(_ tokens: [ResolvedSessionToken]) -> [ResolvedSessionToken] {
        var seen: Set<String> = []
        var deduplicated: [ResolvedSessionToken] = []
        for token in tokens where !token.value.isEmpty {
            if seen.insert(token.value).inserted {
                deduplicated.append(token)
            }
        }
        return deduplicated
    }

    private func cacheTokenIfNeeded(_ token: ResolvedSessionToken, sourceLabel: String) {
        guard token.source.shouldCacheAfterFetch else { return }
        CookieHeaderCache.store(
            provider: .manus,
            cookieHeader: "\(ManusCookieHeader.sessionCookieName)=\(token.value)",
            sourceLabel: sourceLabel)
    }
}
