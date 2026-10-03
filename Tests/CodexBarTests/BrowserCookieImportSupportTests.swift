import Foundation
import SweetCookieKit
import Testing
@testable import CodexBarCore

struct BrowserCookieImportSupportTests {
    @Test
    func `browser labels and keychain requirements follow catalog metadata without discovery`() {
        #expect(BrowserCookieImportSupport.browserNames(for: nil) == "Chrome")
        #expect(BrowserCookieImportSupport.importOrder(for: .museai) == Browser.defaultImportOrder)
        for browser in Browser.allCases {
            #expect(browser.usesKeychainForCookieDecryption == browser.usesChromiumProfileStore)
        }
    }

    @Test(arguments: ["Aside", "Opera", "Opera Neon"])
    func `catalog browsers participate in Muse automatic import`(name: String) throws {
        let browser = try #require(Browser.allCases.first { $0.displayName == name })
        #expect(browser.usesChromiumProfileStore)
        #expect(browser.usesKeychainForCookieDecryption)
        #expect(Browser.defaultImportOrder.contains(browser))
        var visited: [Browser] = []
        let sessions = try BrowserCookieImportSupport.collectSessions(
            from: BrowserCookieImportSupport.importOrder(for: .museai),
            missingError: ImportError.missing,
            logger: { _ in },
            load: { candidate in
                visited.append(candidate)
                return candidate == browser ? ["fixture-session"] : []
            })
        #expect(visited == Browser.defaultImportOrder)
        #expect(sessions == ["fixture-session"])
    }

    @Test
    func `empty session iterators let the plugin classify missing credentials`() throws {
        let sessions: [String] = try BrowserCookieImportSupport.collectSessions(
            from: [.chrome],
            missingError: nil,
            logger: { _ in },
            load: { _ in [] })
        #expect(sessions.isEmpty)
    }

    @Test(arguments: [
        UsageProvider.copilot,
        .grok,
        .helmcode,
        .notion,
        .qoder,
        .replicate,
        .typesafe,
        .venice,
        .zoommate,
    ])
    func `Chrome-only providers retain their bounded browser policy`(provider: UsageProvider) throws {
        let browsers = try #require(ProviderDefaults.metadata[provider]?.browserCookieOrder)
        #expect(browsers == [.chrome])
        var visited: [Browser] = []
        let sessions = try BrowserCookieImportSupport.collectSessions(
            from: browsers,
            missingError: ImportError.missing,
            logger: { _ in },
            load: { browser in
                visited.append(browser)
                return ["fixture-session"]
            })
        #expect(visited == [.chrome])
        #expect(sessions == ["fixture-session"])
    }

    private enum ImportError: Error {
        case missing
        case failed
    }

    @Test
    func `collection preserves browser and session order while continuing after failure`() throws {
        var visited: [Browser] = []
        var messages: [String] = []
        let sessions = try BrowserCookieImportSupport.collectSessions(
            from: [.chrome, .firefox, .safari],
            missingError: ImportError.missing,
            logger: { messages.append($0) },
            load: { browser -> [String] in
                visited.append(browser)
                if browser == .firefox { throw ImportError.failed }
                return ["\(browser.rawValue)-first", "\(browser.rawValue)-second"]
            })
        #expect(visited == [.chrome, .firefox, .safari])
        #expect(sessions == ["chrome-first", "chrome-second", "safari-first", "safari-second"])
        #expect(messages.count == 1)
        #expect(messages.first?.hasPrefix("Firefox cookie import failed: ") == true)
    }

    @Test
    func `empty or failing sources preserve the providers missing session error`() {
        for browsers: [Browser] in [[], [.chrome], [.chrome, .firefox]] {
            #expect(throws: ImportError.missing) {
                let _: [String] = try BrowserCookieImportSupport.collectSessions(
                    from: browsers,
                    missingError: ImportError.missing,
                    logger: { _ in },
                    load: { browser in
                        if browser == .firefox { throw ImportError.failed }
                        return []
                    })
            }
        }
    }

    @Test
    func `HTTP conversion merges stores and omits empty profiles without merging accounts`() throws {
        func source(_ id: String, kind: BrowserCookieStoreKind, value: String?) -> BrowserCookieStoreRecords {
            BrowserCookieStoreRecords(
                store: BrowserCookieStore(
                    browser: .chrome,
                    profile: BrowserProfile(id: id, name: id),
                    kind: kind,
                    label: id + (kind == .network ? " (Network)" : ""),
                    databaseURL: nil),
                records: value.map {
                    [BrowserCookieRecord(
                        domain: "example.test",
                        name: "session",
                        path: "/",
                        value: $0,
                        expires: nil,
                        isSecure: true,
                        isHTTPOnly: true)]
                } ?? [])
        }
        let profiles = BrowserCookieImportSupport.httpCookieProfiles(from: [
            source("Beta", kind: .primary, value: "beta"),
            source("Alpha", kind: .primary, value: "old"),
            source("Alpha", kind: .network, value: "network"),
            source("Empty", kind: .primary, value: nil),
        ], origin: .domainBased)
        #expect(profiles.map(\.label) == ["Alpha", "Beta"])
        #expect(try #require(profiles[0].cookies.first).value == "network")
        #expect(try #require(profiles[1].cookies.first).value == "beta")
        #expect(profiles.allSatisfy { $0.cookies.count == 1 })
    }
}
