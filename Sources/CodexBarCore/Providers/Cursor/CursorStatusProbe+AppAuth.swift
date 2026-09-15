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
    init(
        baseURL: URL = URL(string: "https://cursor.com")!,
        timeout: TimeInterval = 15.0,
        browserDetection: BrowserDetection,
        browserCookieImportOrder: BrowserCookieImportOrder = [],
        urlSession: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        appAuthStore: any CursorAppAuthSessionProviding,
        conditionalMutationCoordinator: CookieHeaderCache.ConditionalMutationCoordinator = .shared)
    {
        self.baseURL = baseURL
        self.timeout = timeout
        self.browserDetection = browserDetection
        self.browserCookieImportOrder = browserCookieImportOrder
        self.urlSession = urlSession
        self.appAuthStore = appAuthStore
        self.conditionalMutationCoordinator = conditionalMutationCoordinator
    }

    /// Called only after manual, cached, and stored sessions have been exhausted.
    func fetchLinuxAppSession<Value: Sendable>(
        log: (String) -> Void,
        perform: @Sendable (String, CursorSessionIdentity?) async throws -> Value) async throws -> Value
    {
        let appSession: CursorAppAuthSession?
        do {
            appSession = try self.appAuthStore.loadSession()
        } catch {
            log("Cursor.app local auth read failed: \(error.localizedDescription)")
            throw CursorStatusProbeError.noSessionCookie
        }
        guard let appSession, appSession.isUsable else {
            throw CursorStatusProbeError.noSessionCookie
        }
        log("Using Cursor.app local auth fallback")
        do {
            return try await perform(appSession.cookieHeader(), appSession.identity)
        } catch let error as CursorStatusProbeError {
            guard case .notLoggedIn = error else { throw error }
            log("Cursor.app local auth was rejected")
            throw CursorStatusProbeError.noSessionCookie
        } catch {
            throw CursorStatusProbeError.networkError(error.localizedDescription)
        }
    }
}
#endif
