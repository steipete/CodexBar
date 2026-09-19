import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct TypeSafeResolvedSession: Sendable {
    let cookieHeader: String
    let sourceLabel: String
}

final class TypeSafeWebFetchStrategy: ProviderFetchStrategy, @unchecked Sendable {
    typealias UsageLoader = @Sendable (String) async throws -> UsageSnapshot
    typealias SessionLoader = @Sendable (BrowserDetection) throws -> [TypeSafeResolvedSession]
    typealias CacheObservation = CookieHeaderCache.ConditionalMutationObservation
    typealias CacheLoader = @Sendable () -> CacheObservation
    typealias CacheClearer = @Sendable (CookieHeaderCache.Entry?) -> Bool
    typealias CacheWriter = @Sendable (CacheObservation, TypeSafeResolvedSession) -> Void

    let id = "typesafe.web"
    let kind: ProviderFetchKind = .web
    private let transport: any ProviderHTTPTransport
    private let usageLoader: UsageLoader?
    private let sessionLoader: SessionLoader
    private let cacheLoader: CacheLoader
    private let cacheClearer: CacheClearer
    private let cacheWriter: CacheWriter
    private let lock = NSLock()
    private var runtime: ProviderPluginRuntime?

    init(
        transport: any ProviderHTTPTransport = TypeSafeWebFetchStrategy.isolatedTransport,
        usageLoader: UsageLoader? = nil,
        sessionLoader: @escaping SessionLoader = TypeSafeWebFetchStrategy.loadSessions,
        cacheLoader: @escaping CacheLoader = { CookieHeaderCache.observeForConditionalMutation(provider: .typesafe) },
        cacheClearer: @escaping CacheClearer = { CookieHeaderCache.clearIfCurrent(provider: .typesafe, expected: $0) },
        cacheWriter: @escaping CacheWriter = { expected, session in
            CookieHeaderCache.storeIfObservationCurrent(
                provider: .typesafe,
                expected: expected,
                cookieHeader: session.cookieHeader,
                sourceLabel: session.sourceLabel)
        })
    {
        self.transport = transport
        self.usageLoader = usageLoader
        self.sessionLoader = sessionLoader
        self.cacheLoader = cacheLoader
        self.cacheClearer = cacheClearer
        self.cacheWriter = cacheWriter
    }

    /// The selected Cookie header is the only credential: no shared jar may add or persist cookies.
    static let isolatedTransport = ProviderHTTPClient(
        session: ProviderHTTPClient.redirectGuardedSession(configuration: TypeSafeWebFetchStrategy.makeConfiguration()))

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return configuration
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        context.settings?.typesafe?.cookieSource != .off
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        try Task.checkCancellation()
        let settings = context.settings?.typesafe
        guard settings?.cookieSource != .off else { throw TypeSafeCredentialError.disabled }
        if settings?.cookieSource == .manual {
            guard let header = CookieHeaderNormalizer.normalize(settings?.manualCookieHeader) else {
                throw TypeSafeCredentialError.invalidCookie
            }
            let usage = try await self.fetchUsage(cookieHeader: header)
            try Task.checkCancellation()
            return self.makeResult(usage: usage, sourceLabel: "web")
        }
        var observation = self.cacheLoader()
        guard case .authoritative = observation else { throw TypeSafeCredentialError.cacheUnavailable }
        if let cached = observation.entry {
            do {
                let usage = try await self.fetchUsage(cookieHeader: cached.cookieHeader)
                try Task.checkCancellation()
                return self.makeResult(usage: usage, sourceLabel: "web")
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
        guard !sessions.isEmpty else { throw TypeSafeCredentialError.missingCookie }
        return try await ProviderCandidateRetryRunner.run(
            sessions,
            shouldRetry: Self.isAuthenticationFailure,
            attempt: { session in
                try Task.checkCancellation()
                let usage = try await self.fetchUsage(cookieHeader: session.cookieHeader)
                try Task.checkCancellation()
                self.cacheWriter(observation, session)
                return self.makeResult(usage: usage, sourceLabel: "web")
            })
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool { false }

    private static func isAuthenticationFailure(_ error: Error) -> Bool {
        (error as? ProviderFetchClassifiedError)?.kind == .authenticationExpired
    }

    private func fetchUsage(cookieHeader: String) async throws -> UsageSnapshot {
        if let usageLoader = self.usageLoader { return try await usageLoader(cookieHeader) }
        let runtime = try self.loadedRuntime()
        return try await runtime.fetchUsage(cookieResolver: { provider, domain in
            guard provider == .typesafe, domain == "typesafe.ai" else {
                throw TypeSafeCredentialError.invalidCookie
            }
            return cookieHeader
        })
    }

    private func loadedRuntime() throws -> ProviderPluginRuntime {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let runtime = self.runtime { return runtime }
        let runtime = try ProviderPluginRuntime(bundledPlugin: "typesafe", transport: self.transport)
        guard runtime.manifest.id == UsageProvider.typesafe.instanceID else {
            throw ProviderPluginError.invalidManifest(
                "bundled plugin id '\(runtime.manifest.id.rawValue)' does not match 'typesafe'")
        }
        self.runtime = runtime
        return runtime
    }

    private static func loadSessions(browserDetection: BrowserDetection) throws -> [TypeSafeResolvedSession] {
        #if os(macOS)
        try TypeSafeCookieImporter.importSessions(browserDetection: browserDetection)
        #else
        throw TypeSafeCredentialError.missingCookie
        #endif
    }
}

enum TypeSafeCredentialError: LocalizedError, Equatable {
    case missingCookie
    case invalidCookie
    case disabled
    case cacheUnavailable

    var errorDescription: String? {
        switch self {
        case .missingCookie:
            "No TypeSafe session cookies found. Sign in at console.typesafe.ai/settings/billing or paste a Cookie header."
        case .invalidCookie:
            "TypeSafe needs a nonempty Cookie header from the billing page."
        case .disabled:
            "TypeSafe cookies are disabled."
        case .cacheUnavailable:
            "TypeSafe's saved session is temporarily unavailable. Unlock the Keychain and retry."
        }
    }
}
