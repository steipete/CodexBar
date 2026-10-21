#if os(Linux)
import CSQLite3
import Foundation
import FoundationNetworking
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CursorAppAuthLinuxTests {
    @Test
    func `repeated app auth refreshes ignore cookies left in the process HTTP session`() async throws {
        let fixture = try Self.makeDatabase(utf16: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let url = try #require(URL(string: "https://cursor-isolation.invalid"))
        let staleCookie = try #require(HTTPCookie(properties: [
            .domain: "cursor-isolation.invalid", .path: "/", .name: "WorkosCursorSessionToken", .value: "stale",
        ]))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CursorCookieIsolationProtocol.self]
        let cookieStorage = try #require(configuration.httpCookieStorage)
        let probe = CursorStatusProbe(
            baseURL: url,
            browserDetection: BrowserDetection(cacheTTL: 0),
            urlSession: CursorStatusProbe.makeHTTPClient(configuration: configuration),
            appAuthStores: [CursorAppAuthStore(dbPath: fixture.database.path)])
        for _ in 0..<3 {
            let snapshot = try await probe.fetch(allowCachedSessions: false)
            #expect(snapshot.planPercentUsed == 30)
            // Simulate Set-Cookie from an earlier response in a long-lived serve process.
            cookieStorage.setCookie(staleCookie)
        }
    }

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

    @Test(arguments: ["/custom/config", "", "relative/config", "~/custom"])
    func `cursor-agent auth path follows the app database's config home`(configHome: String) {
        #expect(CursorAgentAuthStore.resolveDefaultPath(home: "/home/test", environment: [:]) ==
            "/home/test/.config/cursor/auth.json")
        #expect(CursorAgentAuthStore.resolveDefaultPath(
            home: "/home/test",
            environment: ["XDG_CONFIG_HOME": configHome]) ==
            "\(configHome.hasPrefix("/") ? configHome : "/home/test/.config")/cursor/auth.json")
        #expect(CursorAgentAuthStore.resolveDefaultPath(environment: ["HOME": "/home/fixture"]) ==
            "/home/fixture/.config/cursor/auth.json")
        #expect(CursorAgentAuthStore.resolveDefaultPath(environment: ["HOME": "relative/home"]) ==
            "\(NSHomeDirectory())/.config/cursor/auth.json")
    }

    @Test
    func `cursor-agent auth file authenticates without Cursor.app`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = try Self.makeToken()
        let auth = directory.appendingPathComponent("auth.json")
        try Data(#"{"accessToken":"\#(token)","refreshToken":"refresh"}"#.utf8).write(to: auth)
        let before = try Data(contentsOf: auth)
        let probe = CursorStatusProbe(
            browserDetection: BrowserDetection(cacheTTL: 0),
            urlSession: Self.transport(token: token),
            appAuthStores: [
                CursorAppAuthStore(dbPath: directory.appendingPathComponent("missing.vscdb").path),
                CursorAgentAuthStore(path: auth.path),
            ])

        let snapshot = try await probe.fetch(allowCachedSessions: false).toUsageSnapshot()

        #expect(snapshot.primary?.usedPercent == 30)
        #expect(try Data(contentsOf: auth) == before)
    }

    @Test(arguments: [
        #"{"refreshToken":"refresh"}"#,
        "{}",
        #"{"accessToken":null}"#,
        #"{"accessToken":42}"#,
        #"{"accessToken":""}"#,
        #"{"accessToken":"  "}"#,
    ])
    func `cursor-agent auth file without an access token is no session`(json: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let auth = directory.appendingPathComponent("auth.json")
        try Data(json.utf8).write(to: auth)
        #expect(try CursorAgentAuthStore(path: auth.path).loadSession() == nil)
        #expect(try CursorAgentAuthStore(path: directory.appendingPathComponent("none.json").path)
            .loadSession() == nil)
    }

    @Test
    func `local auth stores prefer the first usable session`() async throws {
        let app = try CursorAppAuthSession(accessToken: Self.makeToken())
        let agent = try CursorAppAuthSession(accessToken: Self.makeToken(expiresAt: 4_102_444_801))
        let expired = try CursorAppAuthSession(accessToken: Self.makeToken(expiresAt: 1))
        func first(_ sessions: CursorAppAuthSession?...) async throws -> String {
            let probe = CursorStatusProbe(
                browserDetection: BrowserDetection(cacheTTL: 0),
                appAuthStores: sessions.map { StubAppAuth(session: $0) })
            return try await probe.resolveSession(allowCachedSessions: false) { header, _ in header }
        }
        #expect(try await first(app, agent) == app.cookieHeader())
        #expect(try await first(nil, agent) == agent.cookieHeader())
        #expect(try await first(expired, agent) == agent.cookieHeader())
        await #expect(throws: CursorStatusProbeError.self) { try await first(expired, nil) }
        await #expect(throws: CursorStatusProbeError.self) { try await first(nil, nil) }
    }

    @Test
    func `default Linux probe reads an agent-only login`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let agentDirectory = directory.appendingPathComponent("cursor")
        try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousConfig = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        setenv("XDG_CONFIG_HOME", directory.path, 1)
        defer {
            if let previousConfig {
                setenv("XDG_CONFIG_HOME", previousConfig, 1)
            } else {
                unsetenv("XDG_CONFIG_HOME")
            }
        }
        let token = try Self.makeToken()
        let data = try JSONSerialization.data(withJSONObject: ["accessToken": token, "refreshToken": "fixture"])
        try data.write(to: agentDirectory.appendingPathComponent("auth.json"))
        let probe = CursorStatusProbe(
            browserDetection: BrowserDetection(cacheTTL: 0),
            urlSession: Self.transport(token: token))

        let snapshot = try await probe.fetch(allowCachedSessions: false)
        #expect(snapshot.planPercentUsed == 30)
    }

    @Test(arguments: [401, 403])
    func `rejected desktop login falls through to cursor-agent`(statusCode: Int) async throws {
        let app = try CursorAppAuthSession(accessToken: Self.makeToken())
        let agent = try CursorAppAuthSession(accessToken: Self.makeToken(userID: "agent-user"))
        let acceptedTransport = Self.transport(token: agent.accessToken, userID: "agent-user")
        let transport = ProviderHTTPTransportHandler { request in
            if try request.value(forHTTPHeaderField: "Cookie") == (app.cookieHeader()) {
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil))
                return (Data("{}".utf8), response)
            }
            return try await acceptedTransport.data(for: request)
        }
        let probe = CursorStatusProbe(
            browserDetection: BrowserDetection(cacheTTL: 0),
            urlSession: transport,
            appAuthStores: [StubAppAuth(session: app), StubAppAuth(session: agent)])

        let snapshot = try await probe.fetch(allowCachedSessions: false)
        #expect(snapshot.planPercentUsed == 30)
    }

    @Test(arguments: ["server", "parse", "cancel", "transport"])
    func `local login fallback preserves failures other than authentication`(failure: String) async throws {
        let app = try CursorAppAuthSession(accessToken: Self.makeToken())
        let agent = try CursorAppAuthSession(accessToken: Self.makeToken(expiresAt: 4_102_444_801))
        let probe = CursorStatusProbe(
            browserDetection: BrowserDetection(cacheTTL: 0),
            appAuthStores: [StubAppAuth(session: app), StubAppAuth(session: agent)])
        do {
            let _: String = try await probe.resolveSession(allowCachedSessions: false) { header, _ in
                #expect(try header == (app.cookieHeader()))
                switch failure {
                case "server": throw CursorStatusProbeError.networkError("HTTP 503")
                case "parse": throw CursorStatusProbeError.parseFailed("fixture")
                case "cancel": throw CancellationError()
                default: throw URLError(.timedOut)
                }
            }
            Issue.record("Expected original failure")
        } catch {
            switch failure {
            case "server":
                guard case .networkError("HTTP 503") = error as? CursorStatusProbeError else {
                    Issue.record("Expected server failure")
                    return
                }
            case "parse":
                guard case .parseFailed("fixture") = error as? CursorStatusProbeError else {
                    Issue.record("Expected parse failure")
                    return
                }
            case "cancel": #expect(error is CancellationError)
            default:
                #expect((error as NSError).domain == NSURLErrorDomain)
                #expect((error as NSError).code == URLError.timedOut.rawValue)
            }
        }
    }

    @Test(arguments: ["{", "[]", "null"])
    func `malformed agent files fail without leaking their content`(json: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let auth = directory.appendingPathComponent("auth.json")
        try Data(json.utf8).write(to: auth)
        let error = #expect(throws: CursorStatusProbeError.self) {
            try CursorAgentAuthStore(path: auth.path).loadSession()
        }
        guard case .parseFailed("cursor-agent auth file is not a JSON object")? = error else {
            Issue.record("Expected fixed parse diagnostic")
            return
        }
    }

    @Test
    func `agent login follows symlinks and preserves private file permissions`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let auth = directory.appendingPathComponent("auth.json")
        let link = directory.appendingPathComponent("linked.json")
        let token = try Self.makeToken()
        let data = try JSONSerialization.data(withJSONObject: ["accessToken": " \(token)\n"])
        try data.write(to: auth)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: auth)

        #expect(try CursorAgentAuthStore(path: auth.path).loadSession()?.accessToken == token)
        #expect(try CursorAgentAuthStore(path: link.path).loadSession()?.accessToken == token)
        #expect(try Data(contentsOf: auth) == data)
        #expect(try FileManager.default.attributesOfItem(atPath: auth.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == auth.path)
    }

    @Test(arguments: [false, true])
    func `failed local credential reads do not hide the other login`(agentFails: Bool) async throws {
        let session = try CursorAppAuthSession(accessToken: Self.makeToken())
        let valid = StubAppAuth(session: session)
        let stores: [any CursorAppAuthSessionProviding] = agentFails
            ? [valid, FailingAppAuth()] : [FailingAppAuth(), valid]
        let probe = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0), appAuthStores: stores)
        let header = try await probe.resolveSession(allowCachedSessions: false) { header, identity in
            #expect(identity == session.identity)
            return header
        }
        #expect(try header == (session.cookieHeader()))
    }

    @Test(arguments: ["expired", "invalid", "missing-expiration"])
    func `agent tokens share desktop expiry and validity checks`(kind: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let auth = directory.appendingPathComponent("auth.json")
        let token: String = switch kind {
        case "expired": try Self.makeToken(expiresAt: 1)
        case "missing-expiration": "e30.eyJzdWIiOiJ0ZXN0LXVzZXIifQ.fixture"
        default: "not-a-jwt"
        }
        try JSONSerialization.data(withJSONObject: ["accessToken": token]).write(to: auth)
        let store = CursorAgentAuthStore(path: auth.path)
        let session = try #require(try store.loadSession())
        #expect(!session.isUsable)
        let probe = CursorStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0), appAuthStores: [store])
        let error = await #expect(throws: CursorStatusProbeError.self) {
            try await probe.resolveSession(allowCachedSessions: false) { header, _ in
                Issue.record("Unusable agent credentials must not be sent")
                return header
            }
        }
        guard case .noSessionCookie? = error else {
            Issue.record("Expected existing Linux missing-session diagnostic")
            return
        }
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
        let appAuth = try CountingAppAuth(session: CursorAppAuthSession(accessToken: Self.makeToken()))
        let probe = CursorStatusProbe(
            browserDetection: BrowserDetection(cacheTTL: 0),
            appAuthStores: [appAuth])

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
            appAuthStores: [CursorAppAuthStore(dbPath: fixture.database.path)])

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
            appAuthStores: [StubAppAuth(session: CursorAppAuthSession(accessToken: token))])

        let snapshot = try await probe.fetch(allowCachedSessions: false).toUsageSnapshot()

        #expect(snapshot.primary?.usedPercent == 30)
        #expect(snapshot.extraRateWindows == nil)
    }

    @Test
    func `manual cookie takes precedence without reading app credentials`() async throws {
        let probe = CursorStatusProbe(
            browserDetection: BrowserDetection(cacheTTL: 0),
            appAuthStores: [UnexpectedAppAuth()])
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
            appAuthStores: [UnexpectedAppAuth()])
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
        let appSession = try CursorAppAuthSession(accessToken: Self.makeToken())
        let appCookie = try appSession.makeCookie()
        await CursorSessionStore.shared.setCookies([appCookie])

        let probe = CursorStatusProbe(
            browserDetection: BrowserDetection(cacheTTL: 0),
            appAuthStores: [UnexpectedAppAuth()])
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
        let appAuth = try CountingAppAuth(session: CursorAppAuthSession(accessToken: Self.makeToken()))
        let probe = CursorStatusProbe(
            browserDetection: BrowserDetection(cacheTTL: 0),
            appAuthStores: [appAuth])

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
            appAuthStores: [StubAppAuth(session: CursorAppAuthSession(accessToken: token))])
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

    private static func transport(
        token: String,
        botStatus: Int = 200,
        userID: String = "test-user") -> ProviderHTTPTransportHandler
    {
        ProviderHTTPTransportHandler { request in
            #expect(request.value(forHTTPHeaderField: "Cookie") == "WorkosCursorSessionToken=\(userID)%3A%3A\(token)")
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
                #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first(where: { $0.name == "user" })?.value == userID)
                status = 404
                body = "{}"
            default:
                Issue.record("Unexpected endpoint: \(url.path)")
                throw URLError(.unsupportedURL)
            }
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil))
            return (Data(body.utf8), response)
        }
    }

    private static func makeToken(expiresAt: Double = 4_102_444_800, userID: String = "test-user") throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["sub": "auth0|\(userID)", "exp": expiresAt])
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
        try #require(sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB)", nil, nil, nil) ==
            SQLITE_OK)
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

private struct FailingAppAuth: CursorAppAuthSessionProviding {
    func loadSession() throws -> CursorAppAuthSession? {
        throw CursorStatusProbeError.parseFailed("synthetic unreadable store")
    }
}

private struct UnexpectedAppAuth: CursorAppAuthSessionProviding {
    func loadSession() throws -> CursorAppAuthSession? {
        Issue.record("App credentials must not be read")
        return nil
    }
}

private final class CursorCookieIsolationProtocol: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "cursor-isolation.invalid"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let authenticated = self.request.value(forHTTPHeaderField: "Cookie")?.contains("test-user%3A%3A") == true
        let body = self.request.url?.path == "/api/usage-summary"
            ? #"{"individualUsage":{"plan":{"totalPercentUsed":30,"used":1500,"limit":5000}}}"# : "{}"
        let response = HTTPURLResponse(
            url: self.request.url!, statusCode: authenticated ? 200 : 401, httpVersion: nil, headerFields: nil)!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: Data(body.utf8))
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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
