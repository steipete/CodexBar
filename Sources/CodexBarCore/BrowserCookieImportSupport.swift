import Foundation
#if os(macOS)
import SweetCookieKit
#endif

/// Shared browser policies and traversal; providers retain session validation, caching, and logging.
public enum BrowserCookieImportSupport {
    public static func browserNames(for provider: UsageProvider?) -> String {
        #if os(macOS)
        self.importOrder(for: provider).map(\.displayName).joined(separator: ", ")
        #else
        "none on this platform"
        #endif
    }

    #if os(macOS)
    static func importOrder(for provider: UsageProvider?) -> [Browser] {
        provider.map { ProviderDefaults.metadata[$0]?.browserCookieOrder ?? Browser.defaultImportOrder } ?? [.chrome]
    }

    static func collectSessions<Session>(
        from browsers: some Sequence<Browser>,
        missingError: @autoclosure () -> (any Error)?,
        logger: @escaping (String) -> Void,
        load: @escaping (Browser) throws -> [Session]) throws -> AnySequence<Session>
    {
        var browsers = browsers.makeIterator()
        var pending = [Session]().makeIterator()
        let sessions = AnyIterator<Session> {
            while true {
                if let session = pending.next() { return session }
                guard let browser = browsers.next() else { return nil }
                do {
                    pending = try load(browser).makeIterator()
                } catch {
                    BrowserCookieAccessGate.recordIfNeeded(error)
                    logger("\(browser.displayName) cookie import failed: \(error.localizedDescription)")
                }
            }
        }
        var first = sessions.next()
        if first == nil, let error = missingError() { throw error }
        // A single-pass sequence: later browsers are read only after the caller rejects earlier sessions.
        return AnySequence(AnyIterator {
            defer { first = nil }
            return first ?? sessions.next()
        })
    }

    static func loadProfiles(
        from browser: Browser,
        domains: [String],
        client: BrowserCookieClient,
        logger: @escaping (String) -> Void) throws -> [(label: String, cookies: [HTTPCookie])]
    {
        let query = BrowserCookieQuery(domains: domains)
        let sources = try client.codexBarRecords(matching: query, in: browser, logger: logger)
        return self.httpCookieProfiles(from: sources, origin: query.origin)
    }

    static func httpCookieProfiles(
        from sources: [BrowserCookieStoreRecords],
        origin: BrowserCookieOriginStrategy) -> [(label: String, cookies: [HTTPCookie])]
    {
        BrowserCookieProfiles.merge(sources).compactMap { profile in
            let cookies = BrowserCookieClient.makeHTTPCookies(profile.records, origin: origin)
            return cookies.isEmpty ? nil : (profile.label, cookies)
        }
    }
    #endif
}
