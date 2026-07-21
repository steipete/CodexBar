import Foundation
import SQLite3
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct KiroAPIUsageFetcherTests {
    private struct StubClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
            throw ClaudeUsageError.parseFailed("stub")
        }

        func debugRawProbe(model _: String) async -> String {
            "stub"
        }

        func detectVersion() -> String? {
            nil
        }
    }

    private func makeFetchContext(sourceMode: ProviderSourceMode) -> ProviderFetchContext {
        let env: [String: String] = [:]
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 30,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: ProviderSettingsSnapshot.make(),
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }

    @Test
    func `auto mode ignores social credentials`() throws {
        let env = try self.makeCredentialEnvironment(
            key: KiroCLICredentialStore.socialStorageKey,
            json: Self.socialCredentialJSON)
        defer { try? FileManager.default.removeItem(at: env.root) }

        let store = KiroCLICredentialStore(databaseURL: env.databaseURL)
        #expect(store.loadCredentials(allowSocial: false) == nil)
        #expect(store.loadCredentials(allowSocial: true) != nil)
    }

    @Test
    func `credential keys prefer enterprise oidc before social`() throws {
        let env = try self.makeCredentialEnvironment(
            entries: [
                (KiroCLICredentialStore.socialStorageKey, Self.socialCredentialJSON),
                ("kirocli:oidc:token", Self.idcCredentialJSON),
            ])
        defer { try? FileManager.default.removeItem(at: env.root) }

        let store = KiroCLICredentialStore(databaseURL: env.databaseURL)
        let credentials = store.loadCredentials(allowSocial: false)
        #expect(credentials?.storageKey == "kirocli:oidc:token")
        #expect(credentials?.isEnterpriseAffected == true)
    }

    @Test
    func `odic typo key remains supported`() throws {
        let env = try self.makeCredentialEnvironment(
            key: "kirocli:odic:token",
            json: Self.idcCredentialJSON)
        defer { try? FileManager.default.removeItem(at: env.root) }

        let credentials = KiroCLICredentialStore(databaseURL: env.databaseURL)
            .loadCredentials(allowSocial: false)
        #expect(credentials?.storageKey == "kirocli:odic:token")
    }

    @Test
    func `external idp auth method sends tokentype header`() async throws {
        let env = try self.makeCredentialEnvironment(
            key: "kirocli:oidc:token",
            json: Self.externalIDPCredentialJSON)
        defer { try? FileManager.default.removeItem(at: env.root) }

        let transport = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "tokentype") == "EXTERNAL_IDP")
            #expect(request.url?.absoluteString.contains("profileArn") == false)
            return try Self.httpResponse(data: Self.usageFixture(reset: 1_700_000_000), statusCode: 200)
        }

        let fetcher = KiroAPIUsageFetcher(
            credentialStore: KiroCLICredentialStore(databaseURL: env.databaseURL),
            transport: transport)
        let snapshot = try await fetcher.fetchUsage(allowSocial: false)
        #expect(snapshot.planName == "KIRO POWER")
        #expect(snapshot.creditsUsed == 12.5)
    }

    @Test
    func `idc credentials do not send tokentype header`() async throws {
        let env = try self.makeCredentialEnvironment(
            key: "kirocli:oidc:token",
            json: Self.idcCredentialJSON)
        defer { try? FileManager.default.removeItem(at: env.root) }

        let transport = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "tokentype") == nil)
            return try Self.httpResponse(data: Self.usageFixture(reset: "2026-07-01T00:00:00.000Z"), statusCode: 200)
        }

        let fetcher = KiroAPIUsageFetcher(
            credentialStore: KiroCLICredentialStore(databaseURL: env.databaseURL),
            transport: transport)
        let snapshot = try await fetcher.fetchUsage(allowSocial: false)
        #expect(snapshot.resetsAt != nil)
    }

    @Test
    func `region fallback tries second endpoint after 403`() async throws {
        let env = try self.makeCredentialEnvironment(
            key: "kirocli:oidc:token",
            json: Self.idcCredentialJSON)
        defer { try? FileManager.default.removeItem(at: env.root) }

        let transport = ProviderHTTPTransportStub { request in
            guard let host = request.url?.host else {
                return try Self.httpResponse(data: Data(), statusCode: 500)
            }
            if host == "q.us-east-1.amazonaws.com" {
                return try Self.httpResponse(data: Data("forbidden".utf8), statusCode: 403)
            }
            return try Self.httpResponse(data: Self.usageFixture(reset: 1_700_000_000), statusCode: 200)
        }

        let fetcher = KiroAPIUsageFetcher(
            credentialStore: KiroCLICredentialStore(databaseURL: env.databaseURL),
            transport: transport)
        let snapshot = try await fetcher.fetchUsage(allowSocial: false)
        #expect(snapshot.creditsTotal == 50)
    }

    @Test
    func `expired idc credentials refresh before usage fetch`() async throws {
        let env = try self.makeCredentialEnvironment(
            key: "kirocli:oidc:token",
            json: Self.expiredIDCCredentialJSON)
        defer { try? FileManager.default.removeItem(at: env.root) }

        let transport = ProviderHTTPTransportStub { request in
            if request.url?.host?.hasPrefix("oidc.") == true {
                let body = """
                {"accessToken":"fresh-token","refreshToken":"refresh-abc","expiresIn":3600}
                """
                return try Self.httpResponse(data: Data(body.utf8), statusCode: 200)
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token")
            return try Self.httpResponse(data: Self.usageFixture(reset: 1_700_000_000), statusCode: 200)
        }

        let fetcher = KiroAPIUsageFetcher(
            credentialStore: KiroCLICredentialStore(databaseURL: env.databaseURL),
            transport: transport)
        _ = try await fetcher.fetchUsage(allowSocial: false)
    }

    @Test
    func `refresh failure surfaces authentication error`() async throws {
        let env = try self.makeCredentialEnvironment(
            key: "kirocli:oidc:token",
            json: Self.expiredIDCCredentialJSON)
        defer { try? FileManager.default.removeItem(at: env.root) }

        let transport = ProviderHTTPTransportStub { request in
            if request.url?.host?.hasPrefix("oidc.") == true {
                return try Self.httpResponse(data: Data("{\"error\":\"invalid_grant\"}".utf8), statusCode: 400)
            }
            return try Self.httpResponse(data: Data(), statusCode: 500)
        }

        let fetcher = KiroAPIUsageFetcher(
            credentialStore: KiroCLICredentialStore(databaseURL: env.databaseURL),
            transport: transport)

        await #expect(throws: KiroAPIError.refreshTokenExpired) {
            _ = try await fetcher.fetchUsage(allowSocial: false)
        }
    }

    @Test
    func `machine id derives from refresh token instead of hardware uuid`() {
        let credentials = KiroCLICredentials(
            storageKey: "kirocli:oidc:token",
            accessToken: "token",
            refreshToken: "refresh-token-value",
            expiresAt: nil,
            region: "us-east-1",
            authRegion: nil,
            startURL: nil,
            tokenEndpoint: nil,
            scopes: nil,
            clientID: nil,
            clientSecret: nil,
            authMethod: "idc",
            provider: nil,
            machineID: nil)

        let machineID = KiroAPIUsageFetcher._machineIDForTesting(credentials)
        #expect(machineID.count == 64)
        #expect(machineID == KiroAPIUsageFetcher._machineIDForTesting(credentials))
    }

    @Test
    func `http errors redact sensitive response bodies`() {
        let summary = KiroAPIUsageFetcher._sanitizedResponseBodySummaryForTesting(
            #"{"access_token":"secret-token","message":"bad request"}"#)
        #expect(summary.contains("secret-token") == false)
        #expect(summary.contains("[REDACTED]"))
    }

    @Test
    func `provider descriptor respects explicit source modes`() async {
        let descriptor = KiroProviderDescriptor.descriptor
        let autoContext = self.makeFetchContext(sourceMode: .auto)

        let apiStrategies = await descriptor.fetchPlan.pipeline.resolveStrategies(
            self.makeFetchContext(sourceMode: .api))
        #expect(apiStrategies.count == 1)
        #expect(apiStrategies[0].id == "kiro.api")

        let cliStrategies = await descriptor.fetchPlan.pipeline.resolveStrategies(
            self.makeFetchContext(sourceMode: .cli))
        #expect(cliStrategies.count == 1)
        #expect(cliStrategies[0].id == "kiro.cli")

        let autoStrategies = await descriptor.fetchPlan.pipeline.resolveStrategies(autoContext)
        #expect(autoStrategies.count == 2)
        #expect(autoStrategies[0].id == "kiro.api")
        #expect(autoStrategies[1].id == "kiro.cli")
    }

    @Test
    func `api strategy only falls back in auto mode`() {
        let strategy = KiroAPIFetchStrategy()
        let autoContext = self.makeFetchContext(sourceMode: .auto)
        let apiContext = self.makeFetchContext(sourceMode: .api)

        #expect(strategy.shouldFallback(on: KiroAPIError.authenticationFailed, context: autoContext))
        #expect(!strategy.shouldFallback(on: KiroAPIError.authenticationFailed, context: apiContext))
    }

    // MARK: - Fixtures

    private static let socialCredentialJSON = """
    {"access_token":"social-token","refresh_token":"\(String(repeating: "s", count: 120))","auth_method":"social"}
    """

    private static let idcCredentialJSON = """
    {
      "access_token": "idc-token",
      "refresh_token": "\(String(repeating: "r", count: 120))",
      "auth_method": "idc",
      "region": "us-east-1",
      "client_id": "client-id",
      "client_secret": "client-secret",
      "expires_at": "2099-01-01T00:00:00Z"
    }
    """

    private static let expiredIDCCredentialJSON = """
    {
      "access_token": "stale-token",
      "refresh_token": "\(String(repeating: "r", count: 120))",
      "auth_method": "idc",
      "region": "us-east-1",
      "client_id": "client-id",
      "client_secret": "client-secret",
      "expires_at": "2020-01-01T00:00:00Z"
    }
    """

    private static let externalIDPCredentialJSON = """
    {
      "access_token": "external-token",
      "refresh_token": "\(String(repeating: "e", count: 120))",
      "auth_method": "external_idp",
      "client_id": "client-id",
      "token_endpoint": "https://login.microsoftonline.com/tenant/oauth2/v2.0/token",
      "scopes": "openid offline_access",
      "expires_at": "2099-01-01T00:00:00Z"
    }
    """

    private static func usageFixture(reset: Double) -> Data {
        self.usageFixture(resetJSON: String(reset))
    }

    private static func usageFixture(reset: String) -> Data {
        self.usageFixture(resetJSON: "\"\(reset)\"")
    }

    private static func usageFixture(resetJSON: String) -> Data {
        let body = """
        {
          "nextDateReset": \(resetJSON),
          "subscriptionInfo": { "subscriptionTitle": "KIRO POWER" },
          "usageBreakdownList": [{
            "currentUsage": 12,
            "currentUsageWithPrecision": 12.5,
            "usageLimit": 50,
            "usageLimitWithPrecision": 50.0
          }]
        }
        """
        return Data(body.utf8)
    }

    private static func httpResponse(data: Data, statusCode: Int) throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: URL(string: "https://q.us-east-1.amazonaws.com/getUsageLimits")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil)!
        return (data, response)
    }

    private struct CredentialEnvironment {
        let root: URL
        let databaseURL: URL
    }

    private func makeCredentialEnvironment(
        key: String,
        json: String) throws -> CredentialEnvironment
    {
        try self.makeCredentialEnvironment(entries: [(key, json)])
    }

    private func makeCredentialEnvironment(entries: [(String, String)]) throws -> CredentialEnvironment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KiroAPIUsageFetcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("data.sqlite3")

        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            throw CredentialTestError.sqliteOpen
        }
        defer { sqlite3_close(db) }

        let createSQL = "CREATE TABLE auth_kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);"
        guard sqlite3_exec(db, createSQL, nil, nil, nil) == SQLITE_OK else {
            throw CredentialTestError.sqliteExec
        }

        for (key, json) in entries {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "INSERT INTO auth_kv(key, value) VALUES(?, ?);",
                -1,
                &stmt,
                nil) == SQLITE_OK
            else {
                throw CredentialTestError.sqlitePrepare
            }
            defer { sqlite3_finalize(stmt) }

            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, key, -1, transient)
            sqlite3_bind_text(stmt, 2, json, -1, transient)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw CredentialTestError.sqliteStep
            }
        }

        return CredentialEnvironment(root: root, databaseURL: databaseURL)
    }

    private enum CredentialTestError: Error {
        case sqliteOpen
        case sqliteExec
        case sqlitePrepare
        case sqliteStep
    }
}
