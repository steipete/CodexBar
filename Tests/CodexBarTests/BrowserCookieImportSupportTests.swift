import Foundation
import SweetCookieKit
import Testing
@testable import CodexBarCore

struct BrowserCookieImportSupportTests {
    @Test
    func `mimo candidates leave later browsers unread after a usable Safari session`() throws {
        let detection = BrowserDetection(
            homeDirectory: "/synthetic-mimo-cookie-home",
            cacheTTL: 0,
            now: { Date(timeIntervalSince1970: 0) },
            fileExists: { _ in true },
            directoryContents: { _ in ["Default"] },
            applicationURLs: { _ in [] },
            profileAccessIssue: { _ in nil })
        var visited: [Browser] = []
        let candidates = try MiMoCookieImporter.importSessions(
            browserDetection: detection,
            loadRecords: { browser, _, _ in
                visited.append(browser)
                let store = BrowserCookieStore(
                    browser: browser,
                    profile: .init(id: "Default", name: "Default"),
                    kind: .primary,
                    label: browser.displayName,
                    databaseURL: nil)
                let records = ["api-platform_serviceToken", "userId"].map { name in
                    BrowserCookieRecord(
                        domain: "platform.xiaomimimo.com",
                        name: name,
                        path: "/",
                        value: "fixture",
                        expires: nil,
                        isSecure: true,
                        isHTTPOnly: true)
                }
                return [BrowserCookieStoreRecords(store: store, records: records)]
            },
            loadStores: { _ in [] })
        #expect(candidates.first(where: { _ in true })?.sourceLabel == "Safari")
        #expect(visited == [.safari])
    }

    @Test
    func `usable first session leaves later browsers unread`() throws {
        var visited: [Browser] = []
        let sessions = try BrowserCookieImportSupport.collectSessions(
            from: [.safari, .chrome, .firefox],
            missingError: ImportError.missing,
            logger: { _ in },
            load: { browser in
                visited.append(browser)
                return [browser.rawValue]
            })
        #expect(sessions.first(where: { _ in true }) == "safari")
        #expect(visited == [.safari])
    }

    @Test
    func `rejected first session reads only the next browser`() throws {
        var visited: [Browser] = []
        let sessions = try BrowserCookieImportSupport.collectSessions(
            from: [.safari, .chrome, .firefox],
            missingError: ImportError.missing,
            logger: { _ in },
            load: { browser in
                visited.append(browser)
                return [browser.rawValue]
            })
        #expect(sessions.first(where: { $0 != "safari" }) == "chrome")
        #expect(visited == [.safari, .chrome])
    }

    @Test
    func `background denied Chromium is skipped before a usable browser`() async throws {
        try await BrowserCookieAccessGate.withDeniedBrowsersForTesting([.chrome]) {
            try ProviderInteractionContext.$current.withValue(.background) {
                var visited: [Browser] = []
                let sessions = try BrowserCookieImportSupport.collectSessions(
                    from: [.chrome, .firefox, .safari],
                    missingError: ImportError.missing,
                    logger: { _ in },
                    load: { browser -> [String] in
                        guard BrowserCookieAccessGate.shouldAttempt(browser) else { return [] }
                        visited.append(browser)
                        return [browser.rawValue]
                    })
                #expect(sessions.first(where: { _ in true }) == "firefox")
                #expect(visited == [.firefox])
            }
        }
    }

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
        #expect(Array(sessions) == ["fixture-session"])
        #expect(visited == Browser.defaultImportOrder)
    }

    @Test
    func `automatic plugin import excludes opt in desktop cookies`() {
        #expect(!BrowserCookieImportSupport.importOrder(for: .claude).contains(.claudeDesktop))
        #expect(!BrowserCookieImportSupport.browserNames(for: .claude).contains("Claude desktop app"))
    }

    @Test
    func `empty session iterators let the plugin classify missing credentials`() throws {
        let sessions: AnySequence<String> = try BrowserCookieImportSupport.collectSessions(
            from: [.chrome],
            missingError: nil,
            logger: { _ in },
            load: { _ in [] })
        #expect(Array(sessions).isEmpty)
    }

    @Test
    func `automatic provider cookie orders include every supported browser`() {
        #expect(ReplicateCookieImporter.resolvedImportOrder(nil) == Browser.defaultImportOrder)
        #expect(ReplicateCookieImporter.resolvedImportOrder([]) == Browser.defaultImportOrder)
        for descriptor in ProviderDescriptorRegistry.all {
            // Devin reads Chromium local storage; selected-profile providers honor the user's picker.
            // WorkBuddy sessions bind to the Chrome User-Agent supplied by its host integration.
            guard descriptor.id != .devin, descriptor.id != .workbuddy,
                  descriptor.settingsSection.selectedProfileBrowsers == nil,
                  let order = descriptor.metadata.browserCookieOrder
            else { continue }
            #expect(
                Set(order.filter { $0 != .claudeDesktop }) == Set(Browser.defaultImportOrder),
                "\(descriptor.id) restricts automatic cookie import")
        }
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
        #expect(Array(sessions) == ["chrome-first", "chrome-second", "safari-first", "safari-second"])
        #expect(visited == [.chrome, .firefox, .safari])
        #expect(messages.count == 1)
        #expect(messages.first?.hasPrefix("Firefox cookie import failed: ") == true)
    }

    @Test
    func `empty or failing sources preserve the providers missing session error`() {
        for browsers: [Browser] in [[], [.chrome], [.chrome, .firefox]] {
            #expect(throws: ImportError.missing) {
                let _: AnySequence<String> = try BrowserCookieImportSupport.collectSessions(
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
