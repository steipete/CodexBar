import Foundation
import SweetCookieKit
import Testing
@testable import CodexBarCore

struct CursorAccountSwitchBrowserScanTests {
    private final class LockedArray<Element>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Element] = []

        func append(_ value: Element) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.values.append(value)
        }

        func snapshot() -> [Element] {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.values
        }
    }

    @Test
    func `interactive browser mapping recognizes Comet and Chrome and rejects unknown apps`() {
        let comet = CursorStatusProbe.interactiveBrowser(bundleIdentifier: "ai.perplexity.comet")
        let chrome = CursorStatusProbe.interactiveBrowser(bundleIdentifier: "com.google.Chrome")
        let unknown = CursorStatusProbe.interactiveBrowser(bundleIdentifier: "com.example.unknown")
        let unverifiedArcChannel = CursorStatusProbe.interactiveBrowser(
            bundleIdentifier: "company.thebrowser.Browser.beta")
        let ambiguousYandexChannel = CursorStatusProbe.interactiveBrowser(
            bundleIdentifier: "ru.yandex.desktop.yandex-browser")

        #expect(comet == .comet)
        #expect(chrome == .chrome)
        #expect(unknown == nil)
        #expect(unverifiedArcChannel == nil)
        #expect(ambiguousYandexChannel == nil)
    }

    @Test
    func `interactive browser mapping covers every unambiguous SweetCookieKit browser`() {
        let mapping = CursorStatusProbe.interactiveBrowserByBundleIdentifier
        let mappedBrowsers = Set(mapping.values)
        let deliberatelyUnsupported: Set<Browser> = [.arcBeta, .arcCanary, .yandex]

        #expect(mapping.count == mappedBrowsers.count)
        #expect(mappedBrowsers.isDisjoint(with: deliberatelyUnsupported))
        #expect(mappedBrowsers.union(deliberatelyUnsupported) == Set(Browser.allCases))
        #expect(mapping.keys.allSatisfy { !$0.isEmpty && $0 == $0.lowercased() })
    }

    @Test
    func `interactive browser support requires a readable cookie source`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let applicationURL = temp.appendingPathComponent("Firefox.app", isDirectory: true)
        let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "org.mozilla.firefox",
                "CFBundleName": "Firefox",
            ],
            format: .xml,
            options: 0)
        try info.write(to: contentsURL.appendingPathComponent("Info.plist"))
        defer { try? FileManager.default.removeItem(at: temp) }

        let profileRoot = temp
            .appendingPathComponent("Library/Application Support/Firefox/Profiles", isDirectory: true)
            .path
        let cookieStore = "\(profileRoot)/profile.default-release/cookies.sqlite"
        let makeDetection: (Bool) -> BrowserDetection = { readable in
            BrowserDetection(
                homeDirectory: temp.path,
                cacheTTL: 0,
                now: Date.init,
                fileExists: { path in
                    path == applicationURL.path || path == profileRoot || path == cookieStore
                },
                directoryContents: { path in
                    path == profileRoot && readable ? ["profile.default-release"] : nil
                },
                applicationURLs: { _ in [applicationURL] },
                profileAccessIssue: { _ in readable ? nil : .unreadable })
        }

        #expect(CursorStatusProbe.supportsInteractiveLoginBrowser(
            applicationURL: applicationURL,
            browserDetection: makeDetection(true)))
        let unreadableDetection = makeDetection(false)
        #expect(unreadableDetection.cookieSourceProfileAccessIssue(.firefox) == .unreadable)
        #expect(!CursorStatusProbe.supportsInteractiveLoginBrowser(
            applicationURL: applicationURL,
            browserDetection: unreadableDetection))
    }

    @Test
    func `interactive browser support accepts a renamed installed application`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let applicationURL = try Self.makeBrowserApplication(
            in: temp,
            name: "Work Browser",
            bundleIdentifier: "org.mozilla.firefox")
        defer { try? FileManager.default.removeItem(at: temp) }

        let profileRoot = "\(temp.path)/Library/Application Support/Firefox/Profiles"
        let profileName = "profile.default-release"
        let cookieStore = "\(profileRoot)/\(profileName)/cookies.sqlite"
        let detection = BrowserDetection(
            homeDirectory: temp.path,
            cacheTTL: 0,
            now: Date.init,
            fileExists: { path in
                path == applicationURL.path || path == profileRoot || path == cookieStore
            },
            directoryContents: { path in path == profileRoot ? [profileName] : nil },
            applicationURLs: { _ in [] },
            profileAccessIssue: { path in path == profileRoot ? nil : .unreadable })

        #expect(CursorStatusProbe.interactiveBrowser(forApplicationURL: applicationURL) == .firefox)
        #expect(!detection.isAppInstalled(.firefox))
        #expect(!CursorCookieImporter.isCookieSourceAvailable(
            browser: .firefox,
            browserDetection: detection))
        #expect(CursorCookieImporter.isCookieSourceAvailable(
            browser: .firefox,
            applicationURL: applicationURL,
            browserDetection: detection))
        #expect(detection.isInteractiveCookieSourceAvailable(.firefox, applicationURL: applicationURL))
        #expect(CursorStatusProbe.supportsInteractiveLoginBrowser(
            applicationURL: applicationURL,
            browserDetection: detection))

        let canonicalApplicationPath = "/Applications/Firefox.app"
        let canonicalDetection = BrowserDetection(
            homeDirectory: temp.path,
            cacheTTL: 0,
            now: Date.init,
            fileExists: { path in path == canonicalApplicationPath || path == profileRoot },
            directoryContents: { _ in [] },
            applicationURLs: { _ in [] },
            profileAccessIssue: { path in path == profileRoot ? nil : .unreadable })
        let missingApplicationURL = temp.appendingPathComponent("Removed Browser.app", isDirectory: true)

        #expect(canonicalDetection.isAppInstalled(.firefox))
        #expect(!canonicalDetection.isInteractiveCookieSourceAvailable(
            .firefox,
            applicationURL: missingApplicationURL))
    }

    @Test
    func `interactive Safari support accepts any existing readable source`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let applicationURL = try Self.makeBrowserApplication(
            in: temp,
            name: "Safari",
            bundleIdentifier: "com.apple.Safari")
        defer { try? FileManager.default.removeItem(at: temp) }

        let legacyRoot = "\(temp.path)/Library/Cookies"
        let containerRoot = "\(temp.path)/Library/Containers/com.apple.Safari/Data/Library/Cookies"
        let detection = BrowserDetection(
            homeDirectory: temp.path,
            cacheTTL: 0,
            now: Date.init,
            fileExists: { path in path == legacyRoot || path == containerRoot },
            directoryContents: { _ in nil },
            applicationURLs: { _ in [applicationURL] },
            profileAccessIssue: { path in path == legacyRoot ? .accessDenied : nil })

        #expect(detection.isCookieSourceAvailable(.safari))
        #expect(CursorStatusProbe.supportsInteractiveLoginBrowser(
            applicationURL: applicationURL,
            browserDetection: detection))
    }

    @Test
    func `interactive Safari support rejects missing and denied sources while imports remain eligible`() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let applicationURL = try Self.makeBrowserApplication(
            in: temp,
            name: "Safari",
            bundleIdentifier: "com.apple.Safari")
        defer { try? FileManager.default.removeItem(at: temp) }

        let noRootProbeCalls = LockedArray<String>()
        let noRootDetection = BrowserDetection(
            homeDirectory: temp.path,
            cacheTTL: 0,
            now: Date.init,
            fileExists: { _ in false },
            directoryContents: { _ in nil },
            applicationURLs: { _ in [applicationURL] },
            profileAccessIssue: { path in
                noRootProbeCalls.append(path)
                return nil
            })
        #expect(noRootDetection.isCookieSourceAvailable(.safari))
        #expect(!CursorStatusProbe.supportsInteractiveLoginBrowser(
            applicationURL: applicationURL,
            browserDetection: noRootDetection))
        #expect(noRootProbeCalls.snapshot().isEmpty)

        let legacyRoot = "\(temp.path)/Library/Cookies"
        let deniedDetection = BrowserDetection(
            homeDirectory: temp.path,
            cacheTTL: 0,
            now: Date.init,
            fileExists: { $0 == legacyRoot },
            directoryContents: { _ in nil },
            applicationURLs: { _ in [applicationURL] },
            profileAccessIssue: { _ in .accessDenied })
        #expect(deniedDetection.isCookieSourceAvailable(.safari))
        #expect(!CursorStatusProbe.supportsInteractiveLoginBrowser(
            applicationURL: applicationURL,
            browserDetection: deniedDetection))
    }

    @Test
    func `interactive scan refreshes a cookie store created after browser launch`() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let applicationURL = try Self.makeBrowserApplication(
            in: temp,
            name: "Firefox",
            bundleIdentifier: "org.mozilla.firefox")
        let profile = temp
            .appendingPathComponent("Library/Application Support/Firefox/Profiles/profile.default-release")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let detection = BrowserDetection(
            homeDirectory: temp.path,
            cacheTTL: 600,
            now: Date.init,
            fileExists: { path in
                path == applicationURL.path || FileManager.default.fileExists(atPath: path)
            },
            directoryContents: { path in
                try? FileManager.default.contentsOfDirectory(atPath: path)
            },
            applicationURLs: { _ in [applicationURL] },
            profileAccessIssue: { _ in nil })

        #expect(!detection.isCookieSourceAvailable(.firefox))
        #expect(CursorStatusProbe.supportsInteractiveLoginBrowser(
            applicationURL: applicationURL,
            browserDetection: detection))
        FileManager.default.createFile(
            atPath: profile.appendingPathComponent("cookies.sqlite").path,
            contents: Data())
        #expect(!detection.isCookieSourceAvailable(.firefox))

        let probe = CursorStatusProbe(browserDetection: detection)
        do {
            _ = try await probe.fetchBrowserLoginCandidates(
                browserApplicationURL: applicationURL,
                timeout: 1)
            Issue.record("Expected the isolated browser store to contain no real Cursor session")
        } catch let error as CursorStatusProbeError {
            guard case .noSessionCookie = error else {
                Issue.record("Expected no-session error, got \(error)")
                return
            }
        }

        #expect(detection.isCookieSourceAvailable(.firefox))
    }

    @Test
    func `interactive Comet candidate scan ignores valid Safari account and returns only Comet account`() async throws {
        let probe = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
        let safari = Self.makeSessionInfo(sourceLabel: "Safari Personal")
        let comet = Self.makeSessionInfo(sourceLabel: "Comet Work")
        let fixtures = [
            safari.cookieHeader: Self.snapshot(accountID: "personal-id", email: "personal@example.com"),
            comet.cookieHeader: Self.snapshot(accountID: "work-id", email: "work@example.com"),
        ]
        let importedBrowsers = LockedArray<String>()
        let attemptedHeaders = LockedArray<String>()

        let results = try await probe.fetchBrowserLoginCandidates(
            browser: .comet,
            importSessions: { candidate in
                importedBrowsers.append("strict:\(candidate.displayName)")
                return switch candidate {
                case .safari: [safari]
                case .comet: [comet]
                default: []
                }
            },
            importDomainSessions: { candidate in
                importedBrowsers.append("domain:\(candidate.displayName)")
                return []
            },
            fetchSnapshot: { cookieHeader in
                attemptedHeaders.append(cookieHeader)
                guard let snapshot = fixtures[cookieHeader] else {
                    throw URLError(.badServerResponse)
                }
                return snapshot
            })

        #expect(results.map(\.snapshot.accountID) == ["work-id"])
        #expect(results.map(\.sourceLabel) == ["Comet Work"])
        #expect(importedBrowsers.snapshot() == ["strict:Comet", "domain:Comet"])
        #expect(attemptedHeaders.snapshot() == [comet.cookieHeader])
    }

    @Test
    func `interactive Comet login with no session does not fall back to valid Safari account`() async throws {
        let probe = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
        let safari = Self.makeSessionInfo(sourceLabel: "Safari Personal")
        let importedBrowsers = LockedArray<String>()

        do {
            _ = try await probe.fetchBrowserLoginCandidates(
                browser: .comet,
                importSessions: { candidate in
                    importedBrowsers.append("strict:\(candidate.displayName)")
                    return candidate == .safari ? [safari] : []
                },
                importDomainSessions: { candidate in
                    importedBrowsers.append("domain:\(candidate.displayName)")
                    return candidate == .safari ? [safari] : []
                },
                fetchSnapshot: { _ in
                    Issue.record("No session should be attempted when Comet has no Cursor cookies")
                    throw CursorStatusProbeError.parseFailed("unexpected session")
                })
            Issue.record("Expected the Comet-only scan to remain unresolved")
        } catch let error as CursorStatusProbeError {
            guard case .noSessionCookie = error else {
                Issue.record("Expected no-session error, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected Cursor no-session error, got \(error)")
        }
        #expect(importedBrowsers.snapshot() == ["strict:Comet", "domain:Comet"])
    }

    @Test
    func `browser scan skips rejected old account and caches only accepted new account`() async {
        let probe = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
        let safari = Self.makeSessionInfo(sourceLabel: "Safari")
        let chrome = Self.makeSessionInfo(sourceLabel: "Chrome")
        let fixtures = [
            safari.cookieHeader: Self.snapshot(accountID: "old-id", email: "old@example.com"),
            chrome.cookieHeader: Self.snapshot(accountID: "new-id", email: "new@example.com"),
        ]
        let attemptedHeaders = LockedArray<String>()
        let cachedSources = LockedArray<String>()

        let result = await probe.scanBrowsers(
            [.safari, .chrome],
            importSessions: { browser in
                switch browser {
                case .safari: [safari]
                case .chrome: [chrome]
                default: []
                }
            },
            attemptFetch: { session in
                await probe.fetchIfSessionAccepted(
                    session,
                    log: { _ in },
                    acceptSnapshot: { $0.accountID == "new-id" },
                    fetchSnapshot: { cookieHeader in
                        attemptedHeaders.append(cookieHeader)
                        guard let snapshot = fixtures[cookieHeader] else {
                            throw URLError(.badServerResponse)
                        }
                        return snapshot
                    },
                    cacheAcceptedSession: { cachedSources.append($0.sourceLabel) })
            })

        switch result {
        case let .succeeded(snapshot):
            #expect(snapshot.accountID == "new-id")
        case .exhausted:
            Issue.record("Expected the later Chrome account to be accepted")
        }
        #expect(attemptedHeaders.snapshot() == [safari.cookieHeader, chrome.cookieHeader])
        #expect(cachedSources.snapshot() == ["Chrome"])
    }

    private static func makeSessionInfo(sourceLabel: String) -> CursorCookieImporter.SessionInfo {
        let cookieProps: [HTTPCookiePropertyKey: Any] = [
            .name: "WorkosCursorSessionToken",
            .value: sourceLabel.lowercased(),
            .domain: "cursor.com",
            .path: "/",
            .secure: true,
        ]

        let cookie = HTTPCookie(properties: cookieProps)!
        return CursorCookieImporter.SessionInfo(cookies: [cookie], sourceLabel: sourceLabel)
    }

    private static func makeBrowserApplication(
        in root: URL,
        name: String,
        bundleIdentifier: String) throws -> URL
    {
        let applicationURL = root.appendingPathComponent("\(name).app", isDirectory: true)
        let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": bundleIdentifier,
                "CFBundleName": name,
            ],
            format: .xml,
            options: 0)
        try info.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return applicationURL
    }

    private static func snapshot(accountID: String, email: String) -> CursorStatusSnapshot {
        CursorStatusSnapshot(
            planPercentUsed: 12,
            planUsedUSD: 1,
            planLimitUSD: 20,
            onDemandUsedUSD: 0,
            onDemandLimitUSD: nil,
            teamOnDemandUsedUSD: nil,
            teamOnDemandLimitUSD: nil,
            billingCycleEnd: nil,
            membershipType: "pro",
            accountEmail: email,
            accountID: accountID,
            accountName: nil,
            rawJSON: nil)
    }
}
