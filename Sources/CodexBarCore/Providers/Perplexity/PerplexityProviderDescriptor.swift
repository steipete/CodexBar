import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum PerplexityProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .perplexity,
            metadata: ProviderMetadata(
                id: .perplexity,
                displayName: "Perplexity",
                sessionLabel: "Credits",
                weeklyLabel: "Bonus credits",
                opusLabel: "Purchased",
                supportsOpus: true,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Perplexity usage",
                cliName: "perplexity",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://www.perplexity.ai/account/usage",
                statusPageURL: nil,
                statusLinkURL: "https://status.perplexity.com/"),
            branding: ProviderBranding(
                iconStyle: .perplexity,
                iconResourceName: "ProviderIcon-perplexity",
                color: ProviderColor(red: 32 / 255, green: 178 / 255, blue: 170 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Perplexity cost tracking is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [PerplexityWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "perplexity",
                aliases: [],
                versionDetector: nil))
    }
}

struct PerplexityWebFetchStrategy: ProviderFetchStrategy {
    private enum SessionCookieSource {
        case manual
        case cache
        case browser
        case environment

        var shouldCacheAfterFetch: Bool {
            self == .browser
        }
    }

    private struct ResolvedSessionCookie {
        let value: PerplexityCookieOverride
        let source: SessionCookieSource
    }

    private struct SessionFetchResult {
        let snapshot: PerplexityUsageSnapshot
        let cookie: PerplexityCookieOverride
    }

    let id: String = "perplexity.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.perplexity?.cookieSource != .off else { return false }
        if context.settings?.perplexity?.cookieSource == .manual { return true }

        // Priority order mirrors resolveSessionCookie: manual override → cache → browser import → env var
        if PerplexityCookieHeader.resolveCookieOverride(context: context) != nil {
            return true
        }

        if CookieHeaderCache.load(provider: .perplexity) != nil {
            return true
        }

        #if os(macOS)
        if context.settings?.perplexity?.cookieSource != .off {
            if PerplexityCookieImporter.hasSession() { return true }
        }
        #endif

        if PerplexitySettingsReader.sessionToken(environment: context.env) != nil {
            return true
        }

        return false
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let resolvedCookies = try self.resolveSessionCookies(context: context)
        guard !resolvedCookies.isEmpty else {
            throw PerplexityAPIError.missingToken
        }
        var sawInvalidToken = false

        for resolvedCookie in resolvedCookies {
            do {
                let result = try await self.fetchSnapshot(using: resolvedCookie)
                self.cacheSessionCookieIfNeeded(resolvedCookie, usedCookie: result.cookie, sourceLabel: "web")
                return self.makeResult(
                    usage: result.snapshot.toUsageSnapshot(),
                    sourceLabel: "web")
            } catch PerplexityAPIError.invalidToken {
                sawInvalidToken = true
                if resolvedCookie.source == .cache {
                    CookieHeaderCache.clear(provider: .perplexity)
                }
                continue
            }
        }

        if sawInvalidToken {
            throw PerplexityAPIError.invalidToken
        }
        throw PerplexityAPIError.missingToken
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        if case PerplexityAPIError.missingToken = error { return false }
        if case PerplexityAPIError.invalidCookie = error { return false }
        if case PerplexityAPIError.invalidToken = error { return false }
        return true
    }

    private func resolveSessionCookies(context: ProviderFetchContext) throws -> [ResolvedSessionCookie] {
        guard context.settings?.perplexity?.cookieSource != .off else { return [] }

        if context.settings?.perplexity?.cookieSource == .manual {
            guard let override = PerplexityCookieHeader.resolveCookieOverride(context: context) else {
                throw PerplexityAPIError.invalidCookie
            }
            return [ResolvedSessionCookie(value: override, source: .manual)]
        }

        var cookies: [ResolvedSessionCookie] = []

        // Try cached cookie before expensive browser import
        if let cached = CookieHeaderCache.load(provider: .perplexity) {
            if let override = PerplexityCookieHeader.override(from: cached.cookieHeader) {
                cookies.append(ResolvedSessionCookie(value: override, source: .cache))
            }
        }

        cookies.append(contentsOf: self.resolveSessionCookiesFromBrowserOrEnv(context: context))
        return self.deduplicatedSessionCookies(cookies)
    }

    private func resolveSessionCookiesFromBrowserOrEnv(
        context: ProviderFetchContext,
        preferEnvironment: Bool = false) -> [ResolvedSessionCookie]
    {
        guard context.settings?.perplexity?.cookieSource != .off else { return [] }
        var cookies: [ResolvedSessionCookie] = []

        if preferEnvironment,
           let cookie = PerplexitySettingsReader.sessionCookieOverride(environment: context.env)
        {
            cookies.append(ResolvedSessionCookie(value: cookie, source: .environment))
        }

        // Try browser cookie import when auto mode is enabled
        #if os(macOS)
        do {
            let sessions = try PerplexityCookieImporter.importSessions()
            cookies.append(contentsOf: sessions.compactMap { session in
                guard let cookie = session.sessionCookie else { return nil }
                return ResolvedSessionCookie(value: cookie, source: .browser)
            })
        } catch {
            // No browser cookies found
        }
        #endif

        // Fall back to environment
        if !preferEnvironment,
           let cookie = PerplexitySettingsReader.sessionCookieOverride(environment: context.env)
        {
            cookies.append(ResolvedSessionCookie(value: cookie, source: .environment))
        }
        return self.deduplicatedSessionCookies(cookies)
    }

    private func deduplicatedSessionCookies(_ cookies: [ResolvedSessionCookie]) -> [ResolvedSessionCookie] {
        var deduplicated: [ResolvedSessionCookie] = []
        for cookie in cookies {
            if deduplicated.contains(where: { self.isEquivalentCookie($0.value, cookie.value) }) {
                continue
            }
            deduplicated.append(cookie)
        }
        return deduplicated
    }

    private func cacheSessionCookieIfNeeded(
        _ cookie: ResolvedSessionCookie,
        usedCookie: PerplexityCookieOverride,
        sourceLabel: String)
    {
        guard cookie.source.shouldCacheAfterFetch else { return }
        CookieHeaderCache.store(
            provider: .perplexity,
            cookieHeader: "\(usedCookie.name)=\(usedCookie.token)",
            sourceLabel: sourceLabel)
    }

    private func fetchSnapshot(using cookie: ResolvedSessionCookie) async throws -> SessionFetchResult {
        var lastInvalidToken = false
        for cookieName in cookie.value.requestCookieNames {
            do {
                let snapshot = try await PerplexityUsageFetcher.fetchCredits(
                    sessionToken: cookie.value.token,
                    cookieName: cookieName)
                return SessionFetchResult(
                    snapshot: snapshot,
                    cookie: PerplexityCookieOverride(name: cookieName, token: cookie.value.token))
            } catch PerplexityAPIError.invalidToken {
                lastInvalidToken = true
                continue
            }
        }

        if lastInvalidToken {
            throw PerplexityAPIError.invalidToken
        }
        throw PerplexityAPIError.missingToken
    }

    private func isEquivalentCookie(_ lhs: PerplexityCookieOverride, _ rhs: PerplexityCookieOverride) -> Bool {
        lhs.token == rhs.token && lhs.requestCookieNames == rhs.requestCookieNames
    }
}
