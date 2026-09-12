#if os(Linux)
import CSQLite3
import Foundation
import FoundationNetworking
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CursorAppAuthLinuxTests {
    @Test(arguments: ["/custom/config", "", "relative/config", "~/custom"])
    func `app database path honors only absolute XDG config homes`(configHome: String) {
        let path = CursorAppAuthStore.resolveDefaultDBPath(
            home: "/home/test",
            environment: ["XDG_CONFIG_HOME": configHome])
        let base = configHome.hasPrefix("/") ? configHome : "/home/test/.config"
        #expect(path == "\(base)/Cursor/User/globalStorage/state.vscdb")
    }

    @Test
    func `app database path honors absolute HOME before system home`() {
        let path = CursorAppAuthStore.resolveDefaultDBPath(
            environment: ["HOME": "/tmp/redirected-home"])
        #expect(path == "/tmp/redirected-home/.config/Cursor/User/globalStorage/state.vscdb")
    }

    @Test(arguments: ["", "relative/home", "~/custom"])
    func `app database path ignores non-absolute HOME`(envHome: String) {
        let path = CursorAppAuthStore.resolveDefaultDBPath(
            environment: ["HOME": envHome])
        #expect(path == "\(NSHomeDirectory())/.config/Cursor/User/globalStorage/state.vscdb")
    }

    @Test
    func `app database path keeps injected home ahead of environment HOME`() {
        let path = CursorAppAuthStore.resolveDefaultDBPath(
            home: "/home/injected",
            environment: ["HOME": "/tmp/redirected-home"])
        #expect(path == "/home/injected/.config/Cursor/User/globalStorage/state.vscdb")
    }

    @Test
    func `app database path keeps absolute XDG ahead of HOME`() {
        let path = CursorAppAuthStore.resolveDefaultDBPath(
            environment: [
                "HOME": "/tmp/redirected-home",
                "XDG_CONFIG_HOME": "/custom/config",
            ])
        #expect(path == "/custom/config/Cursor/User/globalStorage/state.vscdb")
    }

    @Test
    func `cached session takes precedence over a valid app token`() async throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        CookieHeaderCache.clear(provider: .cursor)
        defer { CookieHeaderCache.clear(provider: .cursor) }

        let cachedHeader = "WorkosCursorSessionToken=cache-user::cache-token"
        CookieHeaderCache.store(
            provider: .cursor,
            cookieHeader: cachedHeader,
            sourceLabel: "Browser")
        let appAuth = CountingAppAuth(session: CursorAppAuthSession(accessToken: try Self.makeToken()))
        let probe = CursorStatusProbe(
            browserDetection: BrowserDetection(cacheTTL: 0),
            appAuthStore: appAuth)

        let resolved = try await probe.resolveSession(allowCachedSessions: true) { header, _ in
            #expect(header == cachedHeader)
            return header
        }

        #expect(resolved == cachedHeader)
        #expect(appAuth.loadCount == 0)
    }

    @Test(arguments: [false, true])
    func `app database authentication fetches Cursor and Grok Bot usage`(utf16: Bool) async throws {
        let fixture = try Self.makeDatabase(utf16: utf16)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let before = try Data(contentsOf: fixture.database)
        let transport = Self.transport(token: fixture.token)
        let probe = CursorStatusProbe(
            browserDetection: BrowserDetection(cacheTTL: 0),
            urlSession: transport,
            appAuthStore: CursorAppAuthStore(dbPath: fixture.database.path))

        let snapshot = try await probe.fetch(allowCachedSessions: false).toUsageSnapshot()

        #expect(snapshot.primary?.usedPercent == 30)
        let bot = try #require(snapshot.extraRateWindows?.first)
        #expect(bot.id == "cursor-grok-bot")
        #expect(bot.title == "Grok Bot")
        #expect(bot.window.usedPercent == 42)
        #expect(bot.window.windowMinutes == 10080)
        #expect(bot.window.resetsAt != nil)
        #expect(try Data(contentsOf: fixture.database) == before)
    }

    @Test
    func `Grok Bot endpoint failure preserves Cursor usage`() async throws {
        let token = try Self.makeToken()
        let probe = CursorStatusProbe(
            browserDetection: BrowserDetection(cacheTTL: 0),
            urlSession: Self.transport(token: token, botStatus: 503),
            appAuthStore: StubAppAuth(session: CursorAppAuthSession(accessToken: token)))

        let snapshot = try await probe.fetch(allowCachedSessions: false).toUsageSnapshot()

        #expect(snapshot.primary?.usedPercent == 30)
        #expect(snapshot.extraRateWindows == nil)
    }

    @Test
    func `manual cookie takes precedence without reading app credentials`() async throws {
        let probe = CursorStatusProbe(
            browserDetection: BrowserDetection(cacheTTL: 0),
            appAuthStore: UnexpectedAppAuth())
        let header = try await probe.resolveSession(
            cookieHeaderOverride: "WorkosCursorSessionToken=manual",
            allowCachedSessions: false)
        { header, _ in header }
        #expect(header == "WorkosCursorSessionToken=manual")
    }

    @Test
    func `explicit web mode never reads app credentials`() async {
        let probe = CursorStatusProbe(
            browserDetection: BrowserDetection(cacheTTL: 0),
            appAuthStore: UnexpectedAppAuth())
        let error = await #expect(throws: CursorStatusProbeError.self) {
            try await probe.resolveSession(allowCachedSessions: false, allowAppAuthFallback: false) { header, _ in
                Issue.record("No credentials should reach the fetch closure")
                return header
            }
        }
        guard case .noSessionCookie? = error else {
            Issue.record("Expected missing-session error")
            return
        }
    }

    @Test
    func `explicit web mode ignores a persisted app session`() async throws {
        let appSession = CursorAppAuthSession(accessToken: try Self.makeToken())
        let appCookie = try appSession.makeCookie()
        await CursorSessionStore.shared.setCookies([appCookie])

        let probe = CursorStatusProbe(
            browserDetection: BrowserDetection(cacheTTL: 0),
            appAuthStore: UnexpectedAppAuth())
        let error = await #expect(throws: CursorStatusProbeError.self) {
            try await probe.resolveSession(allowCachedSessions: true, allowAppAuthFallback: false) { header, _ in
                Issue.record("Persisted app credentials must not reach explicit web mode")
                return header
            }
        }
        await CursorSessionStore.shared.clearCookies()
        guard case .noSessionCookie? = error else {
            Issue.record("Expected missing-session error")
            return
        }
    }

    @Test
    func `explicit web mode keeps cached session ahead of app credentials`() async throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        CookieHeaderCache.clear(provider: .cursor)
        defer { CookieHeaderCache.clear(provider: .cursor) }

        let cachedHeader = "WorkosCursorSessionToken=web-cache-user::cache-token"
        CookieHeaderCache.store(
            provider: .cursor,
            cookieHeader: cachedHeader,
            sourceLabel: "Browser")
        let appAuth = CountingAppAuth(session: CursorAppAuthSession(accessToken: try Self.makeToken()))
        let probe = CursorStatusProbe(
            browserDetection: BrowserDetection(cacheTTL: 0),
            appAuthStore: appAuth)

        let resolved = try await probe.resolveSession(
            allowCachedSessions: true,
            allowAppAuthFallback: false)
        { header, _ in
            #expect(header == cachedHeader)
            return header
        }

        #expect(resolved == cachedHeader)
        #expect(appAuth.loadCount == 0)
    }

    @Test
    func `expired app tokens are not sent to Cursor`() async throws {
        let token = try Self.makeToken(expiresAt: 1)
        let probe = CursorStatusProbe(
            browserDetection: BrowserDetection(cacheTTL: 0),
            appAuthStore: StubAppAuth(session: CursorAppAuthSession(accessToken: token)))
        let error = await #expect(throws: CursorStatusProbeError.self) {
            try await probe.resolveSession(allowCachedSessions: false) { header, _ in
                Issue.record("Expired credentials should not reach the fetch closure")
                return header
            }
        }
        guard case .noSessionCookie? = error else {
            Issue.record("Expected missing-session error")
            return
        }
    }

    private static func transport(token: String, botStatus: Int = 200) -> ProviderHTTPTransportHandler {
        ProviderHTTPTransportHandler { request in
            #expect(request.value(forHTTPHeaderField: "Cookie") == "WorkosCursorSessionToken=test-user%3A%3A\(token)")
            let url = try #require(request.url)
            let body: String
            var status = 200
            switch url.path {
            case "/api/usage-summary":
                body = """
                {"billingCycleStart":"2026-09-01T00:00:00Z","billingCycleEnd":"2026-10-01T00:00:00Z",
                 "membershipType":"pro","individualUsage":{"plan":{"enabled":true,"used":1500,
                 "limit":5000,"remaining":3500,"totalPercentUsed":30,"autoPercentUsed":10,"apiPercentUsed":20}}}
                """
            case "/api/dashboard/get-sand-usage-status":
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Origin") == "https://cursor.com")
                status = botStatus
                body = """
                {"currentPeriodStart":"2026-09-07T00:00:00Z","nextResetTimestampUtc":"2026-09-14T00:00:00Z",
                 "usagePercent":42,"hasAvailableUsage":true,"hasNonZeroIncludedLimit":true}
                """
            case "/api/auth/me":
                body = "{}"
            case "/api/usage":
                status = 404
                body = "{}"
            default:
                Issue.record("Unexpected endpoint: \(url.path)")
                throw URLError(.unsupportedURL)
            }
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            return (Data(body.utf8), response)
        }
    }

    private static func makeToken(expiresAt: Double = 4102444800) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["sub": "auth0|test-user", "exp": expiresAt])
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(payload).fixture"
    }

    private static func makeDatabase(utf16: Bool) throws -> (directory: URL, database: URL, token: String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("state.vscdb")
        let token = try self.makeToken()
        var db: OpaquePointer?
        try #require(sqlite3_open(database.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB)", nil, nil, nil) == SQLITE_OK)
        var statement: OpaquePointer?
        try #require(sqlite3_prepare_v2(
            db, "INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', ?)", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let data = utf16 ? Data(token.utf8.flatMap { [$0, 0] }) : Data(token.utf8)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), transient)
        }
        try #require(result == SQLITE_OK)
        try #require(sqlite3_step(statement) == SQLITE_DONE)
        return (directory, database, token)
    }
}

private struct StubAppAuth: CursorAppAuthSessionProviding {
    let session: CursorAppAuthSession?
    func loadSession() throws -> CursorAppAuthSession? { self.session }
}

private struct UnexpectedAppAuth: CursorAppAuthSessionProviding {
    func loadSession() throws -> CursorAppAuthSession? {
        Issue.record("App credentials must not be read")
        return nil
    }
}

private final class CountingAppAuth: CursorAppAuthSessionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var loadCount = 0
    let session: CursorAppAuthSession

    init(session: CursorAppAuthSession) {
        self.session = session
    }

    func loadSession() throws -> CursorAppAuthSession? {
        self.lock.lock()
        self.loadCount += 1
        self.lock.unlock()
        return self.session
    }
}
#endif
