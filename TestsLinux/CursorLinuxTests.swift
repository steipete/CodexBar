#if os(Linux)
import CSQLite3
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

private struct CursorLinuxClaudeFetcherStub: ClaudeUsageFetching {
    struct Unavailable: Error {}

    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
        throw Unavailable()
    }

    func debugRawProbe(model _: String) async -> String {
        "stub"
    }

    func detectVersion() -> String? {
        nil
    }
}

private func makeCursorFetchContext(
    sourceMode: ProviderSourceMode,
    settings: ProviderSettingsSnapshot? = nil) -> ProviderFetchContext
{
    ProviderFetchContext(
        runtime: .cli,
        sourceMode: sourceMode,
        includeCredits: false,
        webTimeout: 1,
        webDebugDumpHTML: false,
        verbose: false,
        env: [:],
        settings: settings,
        fetcher: UsageFetcher(environment: [:]),
        claudeFetcher: CursorLinuxClaudeFetcherStub(),
        browserDetection: BrowserDetection(cacheTTL: 0))
}

/// Write a Cursor-style `state.vscdb` with the given ItemTable rows.
private func writeCursorStateDB(at path: String, entries: [(key: String, value: String)]) throws {
    var db: OpaquePointer?
    try #require(sqlite3_open(path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }

    let createTable = "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)"
    try #require(sqlite3_exec(db, createTable, nil, nil, nil) == SQLITE_OK)
    for entry in entries {
        var stmt: OpaquePointer?
        let insert = "INSERT INTO ItemTable (key, value) VALUES (?1, ?2)"
        try #require(sqlite3_prepare_v2(db, insert, -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, entry.key, -1, transient)
        sqlite3_bind_text(stmt, 2, entry.value, -1, transient)
        try #require(sqlite3_step(stmt) == SQLITE_DONE)
    }
}

private struct CursorLinuxAppAuthStoreStub: CursorAppAuthSessionProviding {
    let session: CursorAppAuthSession?

    func loadSession() throws -> CursorAppAuthSession? {
        self.session
    }
}

private func makeCursorLinuxAppTokenJWT() throws -> String {
    let payload = try JSONSerialization.data(
        withJSONObject: [
            "exp": Int(Date(timeIntervalSinceNow: 3600).timeIntervalSince1970),
            "sub": "auth0|user_test",
        ],
        options: [.sortedKeys])
    let encodedPayload = payload.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(encodedPayload).signature"
}

private func makeCursorTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cursor-linux-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

struct CursorLinuxTests {
    @Test
    func `Cursor database path honors absolute XDG config home`() {
        let path = CursorAppAuthStore.resolveDefaultDBPath(
            home: "/home/test",
            environment: ["XDG_CONFIG_HOME": "/custom/config"])
        #expect(path == "/custom/config/Cursor/User/globalStorage/state.vscdb")
    }

    @Test
    func `Cursor database path falls back to dot config`() {
        let path = CursorAppAuthStore.resolveDefaultDBPath(
            home: "/home/test",
            environment: [:])
        #expect(path == "/home/test/.config/Cursor/User/globalStorage/state.vscdb")
    }

    @Test
    func `Cursor database path rejects relative XDG config home`() {
        let path = CursorAppAuthStore.resolveDefaultDBPath(
            home: "/home/test",
            environment: ["XDG_CONFIG_HOME": "relative/config"])
        #expect(path == "/home/test/.config/Cursor/User/globalStorage/state.vscdb")
    }

    @Test
    func `Cursor automatic source does not require macOS web support`() {
        #expect(!CodexBarCLI.sourceModeRequiresWebSupport(
            .auto,
            provider: .cursor,
            settings: ProviderSettingsSnapshot.make(
                cursor: .init(cookieSource: .auto, manualCookieHeader: nil))))
    }

    @Test
    func `Cursor descriptor accepts explicit web source`() {
        #expect(CursorProviderDescriptor.descriptor.fetchPlan.sourceModes.contains(.web))
    }

    @Test
    func `Cursor manual cookie does not require macOS web support`() {
        #expect(!CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .cursor,
            settings: ProviderSettingsSnapshot.make(
                cursor: .init(
                    cookieSource: .manual,
                    manualCookieHeader: "WorkosCursorSessionToken=test"))))
    }

    @Test
    func `disabled Cursor web source still requires macOS web support`() {
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .cursor,
            settings: ProviderSettingsSnapshot.make(
                cursor: .init(cookieSource: .off, manualCookieHeader: nil))))
    }

    @Test
    func `Cursor descriptor accepts explicit oauth source`() {
        #expect(CursorProviderDescriptor.descriptor.fetchPlan.sourceModes.contains(.oauth))
    }

    @Test
    func `Cursor oauth source never requires web support`() {
        #expect(!CodexBarCLI.sourceModeRequiresWebSupport(
            .oauth,
            provider: .cursor,
            settings: ProviderSettingsSnapshot.make(
                cursor: .init(cookieSource: .off, manualCookieHeader: nil))))
    }

    @Test
    func `Cursor oauth mode resolves only the app token strategy`() async {
        let strategies = await CursorProviderDescriptor.descriptor.fetchPlan.pipeline
            .resolveStrategies(makeCursorFetchContext(sourceMode: .oauth))
        #expect(strategies.map(\.id) == ["cursor.oauth"])
    }

    @Test
    func `Cursor auto mode prefers the app token strategy before web`() async {
        let strategies = await CursorProviderDescriptor.descriptor.fetchPlan.pipeline
            .resolveStrategies(makeCursorFetchContext(sourceMode: .auto))
        #expect(strategies.map(\.id) == ["cursor.oauth", "cursor.web"])
    }

    @Test
    func `Cursor app auth store reads token from state database`() throws {
        let directory = try makeCursorTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbPath = directory.appendingPathComponent("state.vscdb").path
        try writeCursorStateDB(at: dbPath, entries: [
            ("cursorAuth/accessToken", "eyJhbGciOiJIUzI1NiJ9.payload.sig"),
        ])

        let session = try #require(try CursorAppAuthStore(dbPath: dbPath).loadSession())
        #expect(session.accessToken == "eyJhbGciOiJIUzI1NiJ9.payload.sig")
    }

    @Test
    func `Cursor app auth store strips surrounding JSON quotes`() throws {
        let directory = try makeCursorTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbPath = directory.appendingPathComponent("state.vscdb").path
        try writeCursorStateDB(at: dbPath, entries: [
            ("cursorAuth/accessToken", "\"tok-123\""),
        ])

        let session = try #require(try CursorAppAuthStore(dbPath: dbPath).loadSession())
        #expect(session.accessToken == "tok-123")
    }

    @Test
    func `Cursor app auth store decodes UTF-16 blob values`() throws {
        let directory = try makeCursorTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbPath = directory.appendingPathComponent("state.vscdb").path
        try writeCursorStateDB(at: dbPath, entries: [])

        var db: OpaquePointer?
        try #require(sqlite3_open(dbPath, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let insert = "INSERT INTO ItemTable (key, value) VALUES (?1, ?2)"
        try #require(sqlite3_prepare_v2(db, insert, -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, "cursorAuth/accessToken", -1, transient)
        let utf16Bytes: [UInt8] = Array("tok-utf16".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        try utf16Bytes.withUnsafeBufferPointer { buffer in
            try #require(sqlite3_bind_blob(
                stmt, 2, buffer.baseAddress, Int32(buffer.count), transient) == SQLITE_OK)
        }
        try #require(sqlite3_step(stmt) == SQLITE_DONE)

        let session = try #require(try CursorAppAuthStore(dbPath: dbPath).loadSession())
        #expect(session.accessToken == "tok-utf16")
    }

    @Test
    func `Cursor app auth store returns nil session without a token row`() throws {
        let directory = try makeCursorTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbPath = directory.appendingPathComponent("state.vscdb").path
        try writeCursorStateDB(at: dbPath, entries: [("someOther/key", "value")])

        #expect(try CursorAppAuthStore(dbPath: dbPath).loadSession() == nil)
    }

    @Test
    func `Cursor app auth store returns nil session without a database`() throws {
        let missing = "/nonexistent/cursor-linux-tests/state.vscdb"
        #expect(try CursorAppAuthStore(dbPath: missing).loadSession() == nil)
    }

    @Test
    func `Cursor app token strategy is unavailable without a database`() async {
        let strategy = CursorAppTokenFetchStrategy(
            appAuthStore: CursorAppAuthStore(dbPath: "/nonexistent/cursor-linux-tests/state.vscdb"),
            loadCachedEntry: { nil })
        #expect(await strategy.isAvailable(makeCursorFetchContext(sourceMode: .oauth)) == false)
    }

    @Test
    func `Cursor app auth cookie header derives from a usable session`() throws {
        let token = try makeCursorLinuxAppTokenJWT()
        let header = CursorStatusProbe.appAuthCookieHeader(
            store: CursorLinuxAppAuthStoreStub(session: CursorAppAuthSession(accessToken: token)))
        #expect(header == "WorkosCursorSessionToken=user_test%3A%3A\(token)")

        #expect(CursorStatusProbe.appAuthCookieHeader(
            store: CursorLinuxAppAuthStoreStub(session: nil)) == nil)
        #expect(CursorStatusProbe.appAuthCookieHeader(
            store: CursorLinuxAppAuthStoreStub(session: CursorAppAuthSession(accessToken: "not-a-jwt"))) == nil)
    }

    @Test
    func `Cursor cost helpers pin oauth source to the app token session`() throws {
        let token = try makeCursorLinuxAppTokenJWT()
        let appHeader = "WorkosCursorSessionToken=user_test%3A%3A\(token)"
        let manualSettings = ProviderSettingsSnapshot.CursorProviderSettings(
            cookieSource: .manual,
            manualCookieHeader: "WorkosCursorSessionToken=manual")

        // App token present: no availability error, and the override is the
        // app session even when a manual cookie is configured.
        #expect(CodexBarCLI.cursorCostAvailabilityError(
            .cursor,
            settings: manualSettings,
            source: .oauth,
            appAuthCookieHeader: { appHeader }) == nil)
        #expect(CodexBarCLI.cursorCostHeaderOverride(
            .cursor,
            settings: manualSettings,
            source: .oauth,
            appAuthCookieHeader: { appHeader }) == appHeader)

        // App token missing: fail closed instead of using other cookies.
        let error = CodexBarCLI.cursorCostAvailabilityError(
            .cursor,
            settings: manualSettings,
            source: .oauth,
            appAuthCookieHeader: { nil })
        #expect(error is CursorCostAvailabilityError)
        #expect(CodexBarCLI.cursorCostHeaderOverride(
            .cursor,
            settings: manualSettings,
            source: .oauth,
            appAuthCookieHeader: { nil }) == nil)

        // Non-oauth sources keep the existing manual-header behavior.
        #expect(CodexBarCLI.cursorCostHeaderOverride(
            .cursor,
            settings: manualSettings,
            source: .auto,
            appAuthCookieHeader: { appHeader }) == "WorkosCursorSessionToken=manual")
    }

    @Test
    func `Cursor auto mode app header defers to explicit selections`() throws {
        let token = try makeCursorLinuxAppTokenJWT()
        let appHeader = "WorkosCursorSessionToken=user_test%3A%3A\(token)"
        let autoSettings = ProviderSettingsSnapshot.CursorProviderSettings(
            cookieSource: .auto,
            manualCookieHeader: nil)
        let manualSettings = ProviderSettingsSnapshot.CursorProviderSettings(
            cookieSource: .manual,
            manualCookieHeader: "WorkosCursorSessionToken=manual")
        let selectedLogin = CookieHeaderCache.Entry(
            cookieHeader: "WorkosCursorSessionToken=selected",
            storedAt: Date(),
            sourceLabel: "Chrome",
            authenticationFailurePolicy: .stopFallback)

        // App token wins plain automatic mode.
        #expect(CursorStatusProbe.autoModeAppAuthCookieHeader(
            cursorSettings: autoSettings,
            cachedEntry: nil,
            appAuthCookieHeader: { appHeader }) == appHeader)

        // Explicit selections defer: manual header or committed browser login.
        #expect(CursorStatusProbe.autoModeAppAuthCookieHeader(
            cursorSettings: manualSettings,
            cachedEntry: nil,
            appAuthCookieHeader: { appHeader }) == nil)
        #expect(CursorStatusProbe.autoModeAppAuthCookieHeader(
            cursorSettings: autoSettings,
            cachedEntry: selectedLogin,
            appAuthCookieHeader: { appHeader }) == nil)

        // A manual source without a usable header cannot pin an account.
        let emptyManualSettings = ProviderSettingsSnapshot.CursorProviderSettings(
            cookieSource: .manual,
            manualCookieHeader: "   ")
        #expect(CursorStatusProbe.autoModeAppAuthCookieHeader(
            cursorSettings: emptyManualSettings,
            cachedEntry: nil,
            appAuthCookieHeader: { appHeader }) == appHeader)

        // No usable app token: the cookie ladder keeps ownership.
        #expect(CursorStatusProbe.autoModeAppAuthCookieHeader(
            cursorSettings: autoSettings,
            cachedEntry: nil,
            appAuthCookieHeader: { nil }) == nil)
    }

    @Test
    func `Cursor cost helpers pin auto source to a winning app token`() throws {
        let token = try makeCursorLinuxAppTokenJWT()
        let appHeader = "WorkosCursorSessionToken=user_test%3A%3A\(token)"
        let autoSettings = ProviderSettingsSnapshot.CursorProviderSettings(
            cookieSource: .auto,
            manualCookieHeader: nil)

        // Auto (explicit or defaulted source) rides the winning app token.
        #expect(CodexBarCLI.cursorCostHeaderOverride(
            .cursor,
            settings: autoSettings,
            source: .auto,
            appAuthCookieHeader: { appHeader }) == appHeader)
        #expect(CodexBarCLI.cursorCostHeaderOverride(
            .cursor,
            settings: autoSettings,
            source: nil,
            appAuthCookieHeader: { appHeader }) == appHeader)

        // An empty manual header is not an error while the app token wins.
        let emptyManualSettings = ProviderSettingsSnapshot.CursorProviderSettings(
            cookieSource: .manual,
            manualCookieHeader: nil)
        #expect(CodexBarCLI.cursorCostAvailabilityError(
            .cursor,
            settings: emptyManualSettings,
            source: .auto,
            appAuthCookieHeader: { appHeader }) == nil)
        #expect(CodexBarCLI.cursorCostHeaderOverride(
            .cursor,
            settings: emptyManualSettings,
            source: .auto,
            appAuthCookieHeader: { appHeader }) == appHeader)

        // Without a winning app token the cookie policy still applies.
        #expect(CodexBarCLI.cursorCostAvailabilityError(
            .cursor,
            settings: emptyManualSettings,
            source: .auto,
            appAuthCookieHeader: { nil }) is CursorCostAvailabilityError)
        #expect(CodexBarCLI.cursorCostHeaderOverride(
            .cursor,
            settings: autoSettings,
            source: .auto,
            appAuthCookieHeader: { nil }) == nil)

        // Explicit web source keeps cookie-ladder behavior even with a token.
        #expect(CodexBarCLI.cursorCostHeaderOverride(
            .cursor,
            settings: autoSettings,
            source: .web,
            appAuthCookieHeader: { appHeader }) == nil)
    }

    @Test
    func `Cursor manual cookie source keeps winning auto mode over app token`() async throws {
        let token = try makeCursorLinuxAppTokenJWT()
        let strategy = CursorAppTokenFetchStrategy(
            appAuthStore: CursorLinuxAppAuthStoreStub(session: CursorAppAuthSession(accessToken: token)),
            loadCachedEntry: { nil })
        let manualSettings = ProviderSettingsSnapshot.make(
            cursor: .init(cookieSource: .manual, manualCookieHeader: "WorkosCursorSessionToken=manual"))

        #expect(await strategy.isAvailable(
            makeCursorFetchContext(sourceMode: .auto, settings: manualSettings)) == false)
        // An explicit oauth selection still uses the app token.
        #expect(await strategy.isAvailable(
            makeCursorFetchContext(sourceMode: .oauth, settings: manualSettings)))
        // Automatic cookie source keeps the token-first ordering.
        #expect(await strategy.isAvailable(makeCursorFetchContext(
            sourceMode: .auto,
            settings: ProviderSettingsSnapshot.make(
                cursor: .init(cookieSource: .auto, manualCookieHeader: nil)))))
    }
}
#endif
