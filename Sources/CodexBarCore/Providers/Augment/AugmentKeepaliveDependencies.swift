import Foundation

#if os(macOS)
import AppKit

@MainActor
struct AugmentKeepaliveDependencies {
    var importSession: (((String) -> Void)?) throws -> AugmentCookieImporter.SessionInfo
    var send: (URLRequest) async throws -> (Data, URLResponse)
    var sleep: (Duration) async throws -> Void
    var storeCookies: ([HTTPCookie]) async -> Void
    var cacheSession: (AugmentCookieImporter.SessionInfo) -> Void
    var openDashboard: () -> Void

    static var live: Self {
        Self(
            importSession: { try AugmentCookieImporter.importSession(logger: $0) },
            send: {
                try Task.checkCancellation()
                return try await ProviderHTTPClient.shared.data(for: $0)
            },
            sleep: { try await Task.sleep(for: $0) },
            storeCookies: { await AugmentSessionStore.shared.setCookies($0) },
            cacheSession: {
                CookieHeaderCache.store(provider: .augment, cookieHeader: $0.cookieHeader, sourceLabel: $0.sourceLabel)
            },
            openDashboard: {
                if let url = URL(string: "https://app.augmentcode.com") { NSWorkspace.shared.open(url) }
            })
    }
}
#endif
