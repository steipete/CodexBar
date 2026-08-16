import Foundation
import SQLite3
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CursorAppAuthRegressionTests {
    @Test
    func `session store replaces app auth accounts and keeps the file owner only`() async throws {
        let store = CursorSessionStore.shared
        await store.clearCookies()
        let firstToken = try makeCursorAppAuthToken(
            subject: "auth0|first-account",
            expiration: Date(timeIntervalSinceNow: 3600))
        let secondToken = try makeCursorAppAuthToken(
            subject: "auth0|second-account",
            expiration: Date(timeIntervalSinceNow: 3600))

        await store.persistAppSession(CursorAppAuthSession(accessToken: firstToken))
        await store.persistAppSession(CursorAppAuthSession(accessToken: secondToken))
        await store.resetForTesting(clearDisk: false)
        let cookies = await store.getCookies()
        let cookie = try #require(cookies.first)

        #expect(cookies.count == 1)
        #expect(!cookie.value.contains(firstToken))
        #expect(cookie.value.contains(secondToken))
        #expect(CursorAppAuthSession.isPersistedCookie(cookie))
        #expect(cookie.expiresDate != nil)

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let fileURL = appSupport
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("cursor-session.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o077 == 0)
        await store.clearCookies()
    }

    @Test
    func `app auth store reads active WAL state without modifying database or WAL`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-app-auth-active-wal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let dbURL = directory.appendingPathComponent("state.vscdb")
        var db: OpaquePointer?
        try #require(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
        let sql = """
        CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value BLOB);
        PRAGMA journal_mode = WAL;
        INSERT INTO ItemTable VALUES('cursorAuth/accessToken', 'active-wal-token');
        """
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }

        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        #expect(FileManager.default.fileExists(atPath: walURL.path))
        let databaseBeforeRead = try Data(contentsOf: dbURL)
        let walBeforeRead = try Data(contentsOf: walURL)
        let session = try #require(try CursorAppAuthStore(dbPath: dbURL.path).loadSession())
        #expect(session.accessToken == "active-wal-token")
        #expect(try Data(contentsOf: dbURL) == databaseBeforeRead)
        #expect(try Data(contentsOf: walURL) == walBeforeRead)
    }

    @Test
    func `explicitly selected browser login stays authoritative in automatic mode`() async throws {
        await CursorSessionStore.shared.clearCookies()
        CookieHeaderCache.clear(provider: .cursor)
        defer { CookieHeaderCache.clear(provider: .cursor) }
        let selectedSession = CursorStatusProbe.BrowserLoginSession(
            cookieHeader: "WorkosCursorSessionToken=selected-browser-session",
            sourceLabel: "Selected browser")
        #expect(CursorStatusProbe.commitBrowserLoginSession(selectedSession))
        let appToken = try makeCursorAppAuthToken(subject: "auth0|app-account")
        let persistence = CursorAppSessionRecorder()
        let probe = CursorStatusProbe(
            browserDetection: BrowserDetection(cacheTTL: 0),
            browserCookieImportOrder: [],
            appAuthStore: CursorAppAuthSessionProviderStub(session: CursorAppAuthSession(accessToken: appToken)),
            persistAppAuthSession: { session in persistence.record(session) })

        let header = try await probe.resolveSession { cookieHeader, _ in cookieHeader }

        #expect(header == selectedSession.cookieHeader)
        #expect(persistence.snapshot().isEmpty)
    }

    @Test
    func `rejected live app auth clears every stale derived app session`() async throws {
        let store = CursorSessionStore.shared
        await store.clearCookies()
        CookieHeaderCache.clear(provider: .cursor)
        defer { CookieHeaderCache.clear(provider: .cursor) }

        let staleToken = try makeCursorAppAuthToken(subject: "auth0|stale-account")
        let liveToken = try makeCursorAppAuthToken(subject: "auth0|live-account")
        let staleCookie = try CursorAppAuthSession(accessToken: staleToken).makeCookie()
        let browserCookie = try #require(HTTPCookie(properties: [
            .name: "WorkosCursorSessionToken",
            .value: "browser-session",
            .domain: "cursor.com",
            .path: "/",
            .secure: true,
        ]))
        await store.setCookies([staleCookie, browserCookie])
        let probe = CursorStatusProbe(
            browserDetection: BrowserDetection(cacheTTL: 0),
            browserCookieImportOrder: [],
            appAuthStore: CursorAppAuthSessionProviderStub(session: CursorAppAuthSession(accessToken: liveToken)))

        let header = try await probe.resolveSession { cookieHeader, _ in
            if cookieHeader.contains(liveToken) {
                throw CursorStatusProbeError.notLoggedIn
            }
            return cookieHeader
        }

        #expect(header == "WorkosCursorSessionToken=browser-session")
        let remainingCookies = await store.getCookies()
        #expect(remainingCookies.count == 1)
        #expect(!remainingCookies.contains(where: CursorAppAuthSession.isPersistedCookie))
        await store.clearCookies()
    }
}
