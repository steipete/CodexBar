import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct ReplicateResolvedSession: Sendable {
    let cookieHeader: String
    let sourceLabel: String
}

struct ReplicateWebFetchStrategy: ProviderFetchStrategy {
    typealias UsageLoader = @Sendable (String) async throws -> UsageSnapshot
    typealias SessionLoader = @Sendable (BrowserDetection) throws -> [ReplicateResolvedSession]
    typealias CacheObservation = CookieHeaderCache.ConditionalMutationObservation
    typealias CacheLoader = @Sendable () -> CacheObservation
    typealias CacheClearer = @Sendable (CookieHeaderCache.Entry?) -> Bool
    typealias CacheWriter = @Sendable (CacheObservation, ReplicateResolvedSession) -> Void

    let id = "replicate.web"
    let kind: ProviderFetchKind = .web
    private let usageLoader: UsageLoader
    private let sessionLoader: SessionLoader
    private let cacheLoader: CacheLoader
    private let cacheClearer: CacheClearer
    private let cacheWriter: CacheWriter

    init(
        usageLoader: @escaping UsageLoader = ReplicateWebFetchStrategy.fetchUsage,
        sessionLoader: @escaping SessionLoader = ReplicateWebFetchStrategy.loadSessions,
        cacheLoader: @escaping CacheLoader = { CookieHeaderCache.observeForConditionalMutation(provider: .replicate) },
        cacheClearer: @escaping CacheClearer = { CookieHeaderCache.clearIfCurrent(provider: .replicate, expected: $0) },
        cacheWriter: @escaping CacheWriter = { expected, session in
            CookieHeaderCache.storeIfObservationCurrent(
                provider: .replicate,
                expected: expected,
                cookieHeader: session.cookieHeader,
                sourceLabel: session.sourceLabel)
        })
    {
        self.usageLoader = usageLoader
        self.sessionLoader = sessionLoader
        self.cacheLoader = cacheLoader
        self.cacheClearer = cacheClearer
        self.cacheWriter = cacheWriter
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        context.settings?.replicate?.cookieSource != .off
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        try Task.checkCancellation()
        let settings = context.settings?.replicate
        guard settings?.cookieSource != .off else { throw ReplicateCredentialError.disabled }
        if settings?.cookieSource == .manual {
            guard let header = CookieHeaderNormalizer.normalize(settings?.manualCookieHeader),
                  CookieHeaderNormalizer.pairs(from: header).contains(where: {
                      $0.name == "sessionid" && !$0.value.isEmpty
                  })
            else { throw ReplicateCredentialError.invalidCookie }
            let usage = try await self.usageLoader(header)
            try Task.checkCancellation()
            return self.makeResult(usage: usage, sourceLabel: "manual")
        }
        var observation = self.cacheLoader()
        guard case .authoritative = observation else { throw ReplicateCredentialError.cacheUnavailable }
        if let cached = observation.entry {
            do {
                let usage = try await self.usageLoader(cached.cookieHeader)
                try Task.checkCancellation()
                return self.makeResult(usage: usage, sourceLabel: cached.sourceLabel)
            } catch {
                try Task.checkCancellation()
                guard Self.isAuthenticationFailure(error) else { throw error }
                guard cached.authenticationFailurePolicy != .stopFallback else { throw error }
                // A late refresh must not erase credentials published by another refresh.
                if self.cacheClearer(cached) { observation = observation.afterOwnedClear() }
            }
        }
        try Task.checkCancellation()
        let sessions = try self.sessionLoader(context.browserDetection)
        guard !sessions.isEmpty else { throw ReplicateCredentialError.missingCookie }
        return try await ProviderCandidateRetryRunner.run(
            sessions,
            shouldRetry: Self.isAuthenticationFailure,
            attempt: { session in
                try Task.checkCancellation()
                let usage = try await self.usageLoader(session.cookieHeader)
                try Task.checkCancellation()
                self.cacheWriter(observation, session)
                return self.makeResult(usage: usage, sourceLabel: session.sourceLabel)
            })
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool { false }

    private static func isAuthenticationFailure(_ error: Error) -> Bool {
        (error as? ProviderFetchClassifiedError)?.kind == .authenticationExpired
    }

    private static func fetchUsage(cookieHeader: String) async throws -> UsageSnapshot {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = ProviderHTTPClient.redirectGuardedSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let runtime = try ProviderPluginRuntime(
            bundledPlugin: "replicate",
            transport: ProviderHTTPClient(session: session))
        return try await runtime.fetchUsage(cookieResolver: { provider, domain in
            guard provider == .replicate, domain == "replicate.com" else {
                throw ReplicateCredentialError.invalidCookie
            }
            return cookieHeader
        })
    }

    private static func loadSessions(browserDetection: BrowserDetection) throws -> [ReplicateResolvedSession] {
        #if os(macOS)
        try ReplicateCookieImporter.importSessions(browserDetection: browserDetection).map {
            ReplicateResolvedSession(cookieHeader: $0.cookieHeader, sourceLabel: $0.sourceLabel)
        }
        #else
        throw ReplicateCredentialError.missingCookie
        #endif
    }
}

enum ReplicateCredentialError: LocalizedError, Equatable {
    case missingCookie
    case invalidCookie
    case disabled
    case cacheUnavailable

    var errorDescription: String? {
        switch self {
        case .missingCookie:
            "No Replicate session cookies found. Sign in at replicate.com/account/billing or paste a Cookie header."
        case .invalidCookie:
            "Replicate needs a Cookie header containing a nonempty sessionid from the billing page."
        case .disabled:
            "Replicate cookies are disabled."
        case .cacheUnavailable:
            "Replicate's saved session is temporarily unavailable. Unlock the Keychain and retry."
        }
    }
}
