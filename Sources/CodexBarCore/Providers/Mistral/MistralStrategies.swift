import Foundation

struct MistralWebFetchStrategy: ProviderFetchStrategy {
    private enum CookieSourceKind {
        case manual
        case environment
        case cache
        case browser

        var shouldCacheAfterFetch: Bool {
            self == .browser
        }
    }

    private struct ResolvedCookie {
        let override: MistralCookieOverride
        let source: CookieSourceKind
        let sourceLabel: String
    }

    let id: String = "mistral.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.mistral?.cookieSource != .off else { return false }

        if context.settings?.mistral?.cookieSource == .manual {
            return MistralCookieHeader.resolveCookieOverride(context: context) != nil
        }

        if MistralSettingsReader.cookieOverride(environment: context.env) != nil {
            return true
        }

        if let cached = CookieHeaderCache.load(provider: .mistral),
           MistralCookieHeader.override(from: cached.cookieHeader) != nil
        {
            return true
        }

        #if os(macOS)
        return MistralCookieImporter.hasSession(browserDetection: context.browserDetection)
        #else
        return false
        #endif
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let cookieSource = context.settings?.mistral?.cookieSource ?? .auto
        let resolvedCookie = try Self.resolveCookie(context: context, allowCached: true)

        do {
            let usage = try await MistralFetcher.fetchBillingUsage(
                cookieHeader: resolvedCookie.override.cookieHeader,
                csrfToken: resolvedCookie.override.csrfToken,
                environment: context.env,
                timeout: context.webTimeout)
            Self.cacheCookieIfNeeded(resolvedCookie)
            return self.makeResult(
                usage: usage.toUsageSnapshot(),
                sourceLabel: "web")
        } catch MistralUsageError.invalidCredentials where cookieSource != .manual {
            #if os(macOS)
            if resolvedCookie.source == .cache {
                CookieHeaderCache.clear(provider: .mistral)
            }
            let refreshedCookie = try Self.resolveCookie(context: context, allowCached: false)
            let usage = try await MistralFetcher.fetchBillingUsage(
                cookieHeader: refreshedCookie.override.cookieHeader,
                csrfToken: refreshedCookie.override.csrfToken,
                environment: context.env,
                timeout: context.webTimeout)
            Self.cacheCookieIfNeeded(refreshedCookie)
            return self.makeResult(
                usage: usage.toUsageSnapshot(),
                sourceLabel: "web")
            #else
            throw MistralUsageError.invalidCredentials
            #endif
        }
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        guard context.sourceMode == .auto else { return false }

        if error is URLError {
            return true
        }

        guard let mistralError = error as? MistralUsageError else { return false }
        switch mistralError {
        case .missingCookie,
             .invalidCookie,
             .invalidCredentials,
             .invalidResponse,
             .networkError,
             .decodeFailed,
             .parseFailed,
             .unexpectedStatus:
            return true
        case .missingToken,
             .unauthorized,
             .rateLimited:
            return false
        }
    }

    private static func resolveCookie(context: ProviderFetchContext, allowCached: Bool) throws -> ResolvedCookie {
        if context.settings?.mistral?.cookieSource == .manual {
            guard let override = MistralCookieHeader.resolveCookieOverride(context: context) else {
                throw MistralUsageError.invalidCookie
            }
            return ResolvedCookie(override: override, source: .manual, sourceLabel: "manual")
        }

        if let envOverride = MistralSettingsReader.cookieOverride(environment: context.env) {
            return ResolvedCookie(override: envOverride, source: .environment, sourceLabel: "environment")
        }

        if allowCached,
           let cached = CookieHeaderCache.load(provider: .mistral),
           let cachedOverride = MistralCookieHeader.override(from: cached.cookieHeader)
        {
            return ResolvedCookie(override: cachedOverride, source: .cache, sourceLabel: cached.sourceLabel)
        }

        #if os(macOS)
        let session = try MistralCookieImporter.importSession(browserDetection: context.browserDetection)
        guard let browserOverride = session.cookieOverride else {
            throw MistralUsageError.missingCookie
        }
        return ResolvedCookie(override: browserOverride, source: .browser, sourceLabel: session.sourceLabel)
        #else
        throw MistralUsageError.missingCookie
        #endif
    }

    private static func cacheCookieIfNeeded(_ cookie: ResolvedCookie) {
        guard cookie.source.shouldCacheAfterFetch else { return }
        CookieHeaderCache.store(
            provider: .mistral,
            cookieHeader: cookie.override.cookieHeader,
            sourceLabel: cookie.sourceLabel)
    }
}

struct MistralAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "mistral.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveToken(environment: context.env) else {
            throw MistralUsageError.missingToken
        }
        let usage = try await MistralFetcher.fetchUsage(
            apiKey: apiKey,
            environment: context.env)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func resolveToken(environment: [String: String]) -> String? {
        ProviderTokenResolver.mistralToken(environment: environment)
    }
}
