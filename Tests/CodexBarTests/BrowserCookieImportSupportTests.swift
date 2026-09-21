import Foundation
import SweetCookieKit
import Testing
@testable import CodexBarCore

struct BrowserCookieImportSupportTests {
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
