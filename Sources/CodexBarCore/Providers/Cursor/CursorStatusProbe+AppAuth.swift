import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS) || os(Linux)
extension CursorStatusProbe {
    /// Fetch Cursor usage using a first-party web session derived from Cursor.app's access token.
    func fetchWithAppAuthSession(_ session: CursorAppAuthSession) async throws -> CursorStatusSnapshot {
        try await self.fetchWithCookieHeader(
            session.cookieHeader(),
            identityFallback: session.identity)
    }
}
#endif

#if os(Linux)
extension CursorStatusProbe {
    private static let httpClient = Self.makeHTTPClient()

    static func makeHTTPClient(
        configuration: URLSessionConfiguration = ProviderHTTPClient.defaultConfiguration()) -> ProviderHTTPClient
    {
        // FoundationNetworking can overwrite an explicit Cookie header from its process-local cookie jar.
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return ProviderHTTPClient(session: ProviderHTTPClient.redirectGuardedSession(configuration: configuration))
    }

    init(
        baseURL: URL = URL(string: "https://cursor.com")!,
        timeout: TimeInterval = 15.0,
        browserDetection: BrowserDetection,
        browserCookieImportOrder: BrowserCookieImportOrder = [],
        urlSession: (any ProviderHTTPTransport)? = nil,
        appAuthStores: [any CursorAppAuthSessionProviding] = [CursorAppAuthStore(), CursorAgentAuthStore()],
        sessionStore: CursorSessionStore = .shared,
        conditionalMutationCoordinator: CookieHeaderCache.ConditionalMutationCoordinator = .shared)
    {
        self.baseURL = baseURL
        self.timeout = timeout
        self.browserDetection = browserDetection
        self.browserCookieImportOrder = browserCookieImportOrder
        self.urlSession = urlSession ?? Self.httpClient
        self.sessionStore = sessionStore
        self.appAuthStores = appAuthStores
        self.conditionalMutationCoordinator = conditionalMutationCoordinator
    }

    /// Called only after manual, cached, and stored sessions have been exhausted.
    func fetchLinuxAppSession<Value: Sendable>(
        log: (String) -> Void,
        perform: @Sendable (String, CursorSessionIdentity?) async throws -> Value) async throws -> Value
    {
        for store in self.appAuthStores {
            try Task.checkCancellation()
            let appSession: CursorAppAuthSession?
            do {
                appSession = try store.loadSession()
            } catch {
                log("Cursor local auth read failed: \(error.localizedDescription)")
                continue
            }
            guard let appSession, appSession.isUsable else { continue }
            log("Using Cursor local auth fallback")
            do {
                return try await perform(appSession.cookieHeader(), appSession.identity)
            } catch let error as CursorStatusProbeError {
                guard case .notLoggedIn = error else { throw error }
                log("Cursor local auth was rejected; trying the next local login")
            } catch {
                throw ProviderTransportError.preservingIdentity(
                    of: error,
                    describedBy: CursorStatusProbeError.networkError(error.localizedDescription))
            }
        }
        throw CursorStatusProbeError.noSessionCookie
    }
}
#endif
