#if os(macOS)

import Foundation
import SQLite3
import Testing
@testable import CodexBarCore

struct OpenCodeGoCLICredentialsReaderTests {
    @Test
    func `outgoing quota requests respect scopes account switching and logout`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase()
        try fixture.writeLegacy(Self.legacy)
        try fixture.insert(integration: "opencode", active: true, value: Self.key)

        let requests = LockIsolated<[URLRequest]>([])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CredentialRequestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            CredentialRequestProtocol.handler.setValue(nil)
        }
        CredentialRequestProtocol.handler.setValue { request in
            var recorded = requests.value
            recorded.append(request)
            requests.setValue(recorded)
            #expect(request.httpMethod == "GET")
            #expect(request.url?.absoluteString == "https://opencode.ai/zen/go/v1/usage")
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]))
            return (response, Data(#"{"usage":{"rolling":{"percent":0},"monthly":{"percent":100}}}"#.utf8))
        }
        let strategy = OpenCodeGoAPIUsageFetchStrategy(usageFetcher: { context, token in
            try await OpenCodeGoUsageFetcher.fetchAPIUsage(
                apiKey: token, timeout: context.webTimeout, session: session)
        })

        let result = try await strategy.fetch(fixture.context())
        #expect(result.sourceLabel == "cli")
        #expect(result.usage.tertiary?.usedPercent == 100)
        #expect(requests.value.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer specific-key"])

        for scope in ["account", "manual-cookie", "workspace", "environment-workspace", "web"] {
            let settings = ProviderSettingsSnapshot.make(opencodego: .init(
                cookieSource: scope == "manual-cookie" ? .manual : .off,
                manualCookieHeader: scope == "manual-cookie" ? "auth=selected-fixture" : nil,
                workspaceID: scope == "workspace" ? "wrk_other_fixture" : nil))
            let context = fixture.context(
                sourceMode: scope == "web" ? .web : .api,
                settings: settings,
                environment: scope == "environment-workspace"
                    ? ["CODEXBAR_OPENCODEGO_WORKSPACE_ID": "wrk_other_fixture"] : [:],
                selectedTokenAccountID: scope == "account" ? UUID() : nil)
            let count = requests.value.count
            await #expect(throws: OpenCodeGoSettingsError.self) { try await strategy.fetch(context) }
            #expect(requests.value.count == count)
        }

        _ = try await strategy.fetch(fixture.context(
            environment: ["OPENCODE_API_KEY": "selected-fixture-key"],
            selectedTokenAccountID: UUID()))
        #expect(requests.value.last?.value(forHTTPHeaderField: "Authorization") == "Bearer selected-fixture-key")

        try fixture.execute("UPDATE credential SET active = 0")
        try fixture.insert(
            integration: "opencode",
            active: true,
            value: #"{"type":"key","key":"switched-fixture-key"}"#)
        _ = try await strategy.fetch(fixture.context())
        #expect(requests.value.map { $0.value(forHTTPHeaderField: "Authorization") } == [
            "Bearer specific-key", "Bearer selected-fixture-key", "Bearer switched-fixture-key",
        ])

        try fixture.execute("UPDATE credential SET active = 0")
        await #expect(throws: OpenCodeGoSettingsError.self) { try await strategy.fetch(fixture.context()) }
        #expect(requests.value.count == 3)
    }

    @Test
    func `active OpenCode API key supplies Go quotas instead of stale legacy auth`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase()
        try fixture.writeLegacy(Self.legacy)
        try fixture.insert(integration: "opencode", active: true, value: Self.key)

        #expect(try fixture.reader.loadCLICredential(now: Self.now) == "specific-key")
    }

    @Test
    func `active OpenCode OAuth takes precedence over an inactive Go key`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase()
        try fixture.insert(integration: "opencode-go", active: false, value: #"{"type":"key","key":"inactive-go"}"#)
        try fixture.insert(
            integration: "opencode",
            active: true,
            value: #"{"type":"oauth","access":"active-oauth","refresh":"fixture-refresh","expires":2000000000000}"#)

        #expect(try fixture.reader.loadCLICredential(now: Date(timeIntervalSince1970: 1_900_000_000)) == "active-oauth")
    }

    @Test(arguments: ["key", "oauth"], ["key", "oauth"])
    func `active specific Go credentials take precedence over the generic login`(
        type: String,
        genericType: String) throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase()
        try fixture.insert(
            integration: "opencode", active: true, value: genericType == "key" ? Self.key : Self.oauth)
        let value = type == "oauth"
            ? #"{"type":"oauth","access":"specific-go","expires":2000000000000}"#
            : #"{"type":"\#(type)","key":"specific-go"}"#
        try fixture.insert(integration: "opencode-go", active: true, value: value)

        #expect(try fixture.reader.loadCLICredential(now: Self.now) == "specific-go")
    }

    @Test(arguments: ["opencode", "opencode-go"])
    func `expired selected OAuth does not switch to another account or legacy key`(integration: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase()
        try fixture.writeLegacy(Self.legacy)
        try fixture.insert(
            integration: integration,
            active: true,
            value: #"{"type":"oauth","access":"expired-access","expires":1900000000000}"#)
        if integration == "opencode-go" {
            try fixture.insert(integration: "opencode", active: true, value: Self.oauth)
        }

        #expect(throws: OpenCodeGoUsageError.self) { try fixture.reader.loadCLICredential(now: Self.now) }
    }

    @Test(arguments: ["empty", "inactive", "deleted", "unrelated"])
    func `modern login state never resurrects stale legacy auth`(state: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase()
        try fixture.writeLegacy(Self.legacy)
        switch state {
        case "inactive":
            try fixture.insert(integration: "opencode-go", active: false, value: Self.key)
        case "deleted":
            try fixture.insert(integration: "opencode-go", active: true, value: Self.key)
            try fixture.execute("DELETE FROM credential")
        case "unrelated":
            try fixture.insert(integration: "another-provider", active: true, value: Self.oauth)
        default: break
        }

        #expect(try fixture.reader.loadCLICredential(now: Self.now) == nil)
    }

    @Test
    func `rereads the active account after switching and renewing credentials`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase()
        try fixture.insert(integration: "opencode", active: true, value: Self.oauth)
        let reader = fixture.reader
        #expect(try reader.loadCLICredential(now: Self.now) == "generic-oauth")

        try fixture.execute("UPDATE credential SET active = 0")
        try fixture.insert(
            integration: "opencode",
            active: true,
            value: #"{"type":"oauth","access":"switched-account","expires":2000000000000}"#)
        #expect(try reader.loadCLICredential(now: Self.now) == "switched-account")

        try fixture.execute("""
        UPDATE credential SET value = '{"type":"oauth","access":"renewed-access","expires":2100000000000}'
        WHERE active = 1
        """)
        #expect(try reader.loadCLICredential(now: Self.now) == "renewed-access")
    }

    @Test(arguments: ["opencode", "opencode-go"])
    func `multiple active accounts in the selected integration are ambiguous`(integration: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase()
        try fixture.insert(integration: integration, active: true, value: Self.oauth)
        try fixture.insert(integration: integration, active: true, value: Self.oauth)

        #expect(throws: OpenCodeGoUsageError.self) { try fixture.reader.loadCLICredential(now: Self.now) }
    }

    @Test
    func `a specific Go account takes precedence over ambiguous generic accounts`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase()
        for _ in 0..<4 {
            try fixture.insert(integration: "opencode", active: true, value: Self.oauth)
        }
        try fixture.insert(integration: "opencode-go", active: true, value: Self.key)

        #expect(try fixture.reader.loadCLICredential(now: Self.now) == "specific-key")
    }

    @Test(arguments: [
        "{", #"{"type":"key","key":12}"#,
        #"{"type":"key","key":"fixture\nheader"}"#, #"{"type":"external"}"#,
        #"{"type":"oauth","access":"fixture"}"#,
        #"{"type":"oauth","access":"fixture","expires":true}"#,
        #"{"type":"oauth","access":"fixture","expires":2000000000000.5}"#,
    ])
    func `invalid selected credentials fail without switching accounts`(value: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase()
        try fixture.insert(integration: "opencode", active: true, value: Self.oauth)
        try fixture.insert(integration: "opencode-go", active: true, value: value)
        try fixture.writeLegacy(Self.legacy)

        #expect(throws: OpenCodeGoUsageError.self) { try fixture.reader.loadCLICredential(now: Self.now) }
    }

    @Test
    func `invalid inactive credentials do not poison the selected account`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase()
        try fixture.insert(integration: "opencode-go", active: false, value: "{")
        try fixture.insert(integration: "opencode", active: true, value: Self.oauth)

        #expect(try fixture.reader.loadCLICredential(now: Self.now) == "generic-oauth")
    }

    @Test(arguments: ["NULL", "12", "X'7B7D'"])
    func `nontext SQLite credential payloads are malformed`(value: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase()
        try fixture.insert(integration: "opencode-go", active: true, value: Self.key)
        try fixture.execute("UPDATE credential SET value = \(value)")

        #expect(throws: OpenCodeGoUsageError.self) { try fixture.reader.loadCLICredential(now: Self.now) }
    }

    @Test(arguments: [false, true])
    func `legacy Go api key is used only before the credential table exists`(hasDatabase: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        if hasDatabase { try fixture.execute("CREATE TABLE legacy_fixture (id TEXT)") }
        try fixture.writeLegacy(Self.legacy)

        #expect(try fixture.reader.loadCLICredential(now: Self.now) == "legacy-go")
    }

    @Test(arguments: [
        #"{"opencode":{"type":"api","key":"generic-key"}}"#,
        #"{"opencode-go":{"type":"key","key":"unsupported-legacy"}}"#,
        #"{"opencode-go":{"type":"oauth","access":"unsupported-legacy","expires":2000000000000}}"#,
    ])
    func `legacy fallback ignores other integrations and unsupported credential types`(json: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeLegacy(json)

        #expect(try fixture.reader.loadCLICredential(now: Self.now) == nil)
    }

    @Test
    func `missing database is never created`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(try fixture.reader.loadCLICredential(now: Self.now) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.database.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    @Test(arguments: ["absolute", "relative", "xdg", "relative-xdg"])
    func `resolves only the configured database path`(override: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let database: URL
        let environment: [String: String]
        switch override {
        case "absolute":
            database = fixture.home.appendingPathComponent("custom/channel.db")
            environment = ["OPENCODE_DB": database.path]
        case "relative":
            database = fixture.directory.appendingPathComponent("custom/channel.db")
            environment = ["OPENCODE_DB": "custom/channel.db"]
        case "xdg":
            let data = fixture.home.appendingPathComponent("xdg")
            database = data.appendingPathComponent("opencode/opencode.db")
            environment = ["XDG_DATA_HOME": data.path]
        default:
            database = fixture.database
            environment = ["XDG_DATA_HOME": "relative-path-is-ignored"]
        }
        try fixture.createDatabase(at: database)
        try fixture.insert(integration: "opencode-go", active: true, value: Self.key, at: database)
        #expect(try OpenCodeGoLocalUsageReader.loadCLICredential(
            environment: environment, homeDirectory: fixture.home, now: Self.now) == "specific-key")
    }

    @Test
    func `in memory override does not read the release database or legacy credentials`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase()
        try fixture.insert(integration: "opencode-go", active: true, value: Self.key)
        try fixture.writeLegacy(Self.legacy)
        #expect(try OpenCodeGoLocalUsageReader.loadCLICredential(
            environment: ["OPENCODE_DB": ":memory:"], homeDirectory: fixture.home, now: Self.now) == nil)
    }

    @Test
    func `missing override does not search the release database or other channel files`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase()
        try fixture.insert(integration: "opencode-go", active: true, value: Self.key)
        let channel = fixture.directory.appendingPathComponent("opencode-local.db")
        try fixture.createDatabase(at: channel)
        try fixture.insert(integration: "opencode-go", active: true, value: Self.key, at: channel)
        #expect(try OpenCodeGoLocalUsageReader.loadCLICredential(
            environment: ["OPENCODE_DB": "missing.db"], homeDirectory: fixture.home, now: Self.now) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("missing.db").path))
    }

    @Test
    func `legacy auth follows the absolute XDG data directory even with a database override`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeLegacy(#"{"opencode-go":{"type":"api","key":"wrong-directory"}}"#)
        let xdg = fixture.home.appendingPathComponent("xdg")
        let directory = xdg.appendingPathComponent("opencode")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(Self.legacy.utf8).write(to: directory.appendingPathComponent("auth.json"))
        #expect(try OpenCodeGoLocalUsageReader.loadCLICredential(
            environment: ["XDG_DATA_HOME": xdg.path, "OPENCODE_DB": "custom/missing.db"],
            homeDirectory: fixture.home,
            now: Self.now) == "legacy-go")
    }

    @Test
    func `reading credentials leaves the main database unchanged`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase()
        try fixture.insert(integration: "opencode-go", active: true, value: Self.key)
        let before = try Data(contentsOf: fixture.database)

        #expect(try fixture.reader.loadCLICredential(now: Self.now) == "specific-key")
        #expect(try Data(contentsOf: fixture.database) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path) == ["opencode.db"])
    }

    @Test(arguments: ["corrupt", "schema", "locked"])
    func `unreadable modern database never falls back to stale legacy credentials`(failure: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeLegacy(Self.legacy)
        var lock: OpaquePointer?
        defer {
            sqlite3_exec(lock, "ROLLBACK", nil, nil, nil)
            sqlite3_close(lock)
        }
        switch failure {
        case "corrupt":
            try Data("invalid-sqlite-fixture".utf8).write(to: fixture.database)
        case "schema":
            try fixture.execute("CREATE TABLE credential (id TEXT)")
        default:
            try fixture.createDatabase()
            try #require(sqlite3_open_v2(fixture.database.path, &lock, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
            try #require(sqlite3_exec(lock, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
        }

        #expect(throws: OpenCodeGoUsageError.self) { try fixture.reader.loadCLICredential(now: Self.now) }
    }

    @Test
    func `reads idle WAL credentials without creating sidecars`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase()
        try fixture.insert(integration: "opencode-go", active: true, value: Self.key)
        try fixture.execute("PRAGMA journal_mode = WAL; PRAGMA wal_checkpoint(TRUNCATE);")
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: fixture.database.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try FileManager.default.removeItem(at: sidecar)
            }
        }
        let before = try Data(contentsOf: fixture.database)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path)
        }

        #expect(try fixture.reader.loadCLICredential(now: Self.now) == "specific-key")
        #expect(try Data(contentsOf: fixture.database) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path) == ["opencode.db"])
    }

    @Test
    func `reads active WAL updates instead of an immutable main file`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase()
        try fixture.insert(integration: "opencode-go", active: true, value: Self.key)
        var writer: OpaquePointer?
        try #require(sqlite3_open_v2(fixture.database.path, &writer, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close(writer) }
        let sql = """
        PRAGMA journal_mode = WAL;
        PRAGMA wal_autocheckpoint = 0;
        UPDATE credential SET value = '{"type":"key","key":"latest-wal-key"}';
        """
        try #require(sqlite3_exec(writer, sql, nil, nil, nil) == SQLITE_OK)
        let wal = URL(fileURLWithPath: fixture.database.path + "-wal")
        let walContents = try Data(contentsOf: wal)
        #expect(!walContents.isEmpty)

        #expect(try fixture.reader.loadCLICredential(now: Self.now) == "latest-wal-key")
    }

    @Test
    func `symlinked databases never bypass an unreadable active WAL`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase()
        try fixture.insert(integration: "opencode-go", active: true, value: Self.key)
        var writer: OpaquePointer?
        try #require(sqlite3_open_v2(fixture.database.path, &writer, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close(writer) }
        let sql = """
        PRAGMA journal_mode = WAL;
        PRAGMA wal_checkpoint(TRUNCATE);
        DELETE FROM credential;
        """
        try #require(sqlite3_exec(writer, sql, nil, nil, nil) == SQLITE_OK)
        let link = fixture.home.appendingPathComponent("linked.db")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.database)
        let wal = URL(fileURLWithPath: fixture.database.path + "-wal")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: wal.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: wal.path) }
        #expect(throws: OpenCodeGoUsageError.self) {
            try OpenCodeGoLocalUsageReader.loadCLICredential(
                environment: ["OPENCODE_DB": link.path], homeDirectory: fixture.home, now: Self.now)
        }
    }

    @Test
    func `inaccessible modern database never revives readable legacy credentials`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeLegacy(Self.legacy)
        let directory = fixture.home.appendingPathComponent("restricted")
        let database = directory.appendingPathComponent("modern.db")
        try fixture.createDatabase(at: database)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        #expect(throws: OpenCodeGoUsageError.self) {
            try OpenCodeGoLocalUsageReader.loadCLICredential(
                environment: ["OPENCODE_DB": database.path], homeDirectory: fixture.home, now: Self.now)
        }
    }

    private static let now = Date(timeIntervalSince1970: 1_900_000_000)
    private static let key = #"{"type":"key","key":"specific-key"}"#
    private static let oauth = #"{"type":"oauth","access":"generic-oauth","expires":2000000000000}"#
    private static let legacy = #"{"opencode-go":{"type":"api","key":"legacy-go"}}"#

    private struct Fixture {
        let home: URL
        var directory: URL {
            self.home.appendingPathComponent(".local/share/opencode")
        }

        var database: URL {
            self.directory.appendingPathComponent("opencode.db")
        }

        var reader: OpenCodeGoLocalUsageReader {
            OpenCodeGoLocalUsageReader(
                authURL: self.directory.appendingPathComponent("auth.json"),
                databaseURL: self.database)
        }

        func context(
            sourceMode: ProviderSourceMode = .api,
            settings: ProviderSettingsSnapshot? = nil,
            environment: [String: String] = [:],
            selectedTokenAccountID: UUID? = nil) -> ProviderFetchContext
        {
            let environment = ["XDG_DATA_HOME": self.home.appendingPathComponent(".local/share").path]
                .merging(environment, uniquingKeysWith: { _, override in override })
            let browserDetection = BrowserDetection(cacheTTL: 0)
            return ProviderFetchContext(
                runtime: .cli,
                sourceMode: sourceMode,
                includeCredits: false,
                includeOptionalUsage: false,
                webTimeout: 1,
                webDebugDumpHTML: false,
                verbose: false,
                env: environment,
                settings: settings,
                fetcher: UsageFetcher(environment: environment),
                claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection, environment: environment),
                browserDetection: browserDetection,
                selectedTokenAccountID: selectedTokenAccountID)
        }

        init() throws {
            self.home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: self.home) }

        func writeLegacy(_ json: String) throws {
            try Data(json.utf8).write(to: self.directory.appendingPathComponent("auth.json"))
        }

        func createDatabase(at url: URL? = nil) throws {
            try self.execute("""
            CREATE TABLE credential (
                id TEXT PRIMARY KEY, integration_id TEXT, label TEXT, value TEXT,
                connector_id TEXT, method_id TEXT, active INTEGER,
                time_created INTEGER, time_updated INTEGER
            );
            """, at: url)
        }

        func insert(integration: String, active: Bool, value: String, at url: URL? = nil) throws {
            let escaped = value.replacingOccurrences(of: "'", with: "''")
            try self.execute("""
            INSERT INTO credential VALUES (
                '\(UUID().uuidString)', '\(integration)', 'fixture', '\(escaped)',
                NULL, NULL, \(active ? 1 : 0), 0, 0
            );
            """, at: url)
        }

        func execute(_ sql: String, at url: URL? = nil) throws {
            let url = url ?? self.database
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            var database: OpaquePointer?
            let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
            defer { sqlite3_close(database) }
            try #require(result == SQLITE_OK)
            try #require(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        }
    }

    private final class CredentialRequestProtocol: URLProtocol {
        static let handler = LockIsolated<(@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)

        override static func canInit(with _: URLRequest) -> Bool { true }
        override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            do {
                let handler = try #require(Self.handler.value)
                let (response, data) = try handler(self.request)
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            } catch {
                self.client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }
}
#endif
