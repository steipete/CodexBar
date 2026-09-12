import Foundation

/// A Venice web session resolved from imported browser cookies.
public struct VeniceResolvedSession: Sendable {
    public let cookieHeader: String
    public let sourceLabel: String

    public init(cookieHeader: String, sourceLabel: String) {
        self.cookieHeader = cookieHeader
        self.sourceLabel = sourceLabel
    }
}

/// Explicit-web-only strategy for Venice subscription quota via the signed-in
/// venice.ai session. Unlike the API-key script strategy, this never runs in
/// automatic mode: importing browser cookies can surface an OS permission
/// prompt, so it only runs when the caller explicitly selects the web source.
struct VeniceWebFetchStrategy: ProviderFetchStrategy {
    typealias UsageLoader = @Sendable (String) async throws -> UsageSnapshot
    typealias SessionLoader = @Sendable () throws -> [VeniceResolvedSession]

    let id: String = "venice.web"
    let kind: ProviderFetchKind = .web

    private let usageLoader: UsageLoader
    private let sessionLoader: SessionLoader

    init(
        usageLoader: UsageLoader? = nil,
        sessionLoader: SessionLoader? = nil,
        timeout: TimeInterval = VeniceWebUsageFetcher.defaultTimeout)
    {
        self.usageLoader = usageLoader ?? { header in
            try await VeniceWebUsageFetcher.fetchUsage(cookieHeader: header, timeout: timeout)
        }
        self.sessionLoader = sessionLoader ?? { try Self.defaultSessions() }
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        // A selected token account is an authority boundary: ambient browser
        // sessions must never be fetched and labeled as that account.
        guard context.selectedTokenAccountID == nil else { return false }
        guard context.sourceMode == .web else { return false }
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard context.selectedTokenAccountID == nil else {
            throw VeniceUsageError.tokenAccountUnsupported
        }
        guard context.sourceMode == .web else { throw VeniceUsageError.missingCredentials }
        // An explicitly stored manual cookie wins over ambient browser
        // sessions: it is the user's deliberate credential, and it keeps web
        // quota working where the browser profile is unreadable.
        if context.settings?.venice?.cookieSource == .manual {
            guard let manual = Self.manualCookieHeader(from: context) else {
                throw VeniceUsageError.missingCredentials
            }
            let usage = try await self.usageLoader(manual)
            return self.makeResult(usage: usage, sourceLabel: "manual cookie")
        }
        let sessions = try self.sessionLoader()
        guard !sessions.isEmpty else { throw VeniceUsageError.missingCredentials }
        var lastError: (any Error)?
        for session in sessions {
            do {
                let usage = try await self.usageLoader(session.cookieHeader)
                return self.makeResult(usage: usage, sourceLabel: session.sourceLabel)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as VeniceUsageError where error.isSessionAuthenticationFailure {
                lastError = error
                continue
            } catch {
                throw error
            }
        }
        throw lastError ?? VeniceUsageError.missingCredentials
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func manualCookieHeader(from context: ProviderFetchContext) -> String? {
        guard context.settings?.venice?.cookieSource == .manual else { return nil }
        return VeniceCookieHeader.header(from: context.settings?.venice?.manualCookieHeader)
    }

    #if os(macOS)
    private static func defaultSessions() throws -> [VeniceResolvedSession] {
        try VeniceCookieImporter.importSessions().map {
            VeniceResolvedSession(cookieHeader: $0.cookieHeader, sourceLabel: $0.sourceLabel)
        }
    }
    #else
    private static func defaultSessions() throws -> [VeniceResolvedSession] {
        []
    }
    #endif
}
