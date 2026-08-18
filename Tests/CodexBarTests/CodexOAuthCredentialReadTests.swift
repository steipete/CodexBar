import Foundation
import Testing
@testable import CodexBarCore

struct CodexOAuthCredentialReadTests {
    @Test
    func `missing auth json maps to a not found credential error`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let error = #expect(throws: CodexOAuthCredentialsError.self) {
            try CodexOAuthCredentialsStore.loadOAuthTokens(env: ["CODEX_HOME": home.path])
        }
        guard case .notFound = error else {
            Issue.record("Expected a missing auth file to remain distinguishable")
            return
        }
    }

    @Test
    func `unreadable auth json maps to an unreadable credential error`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-unreadable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("auth.json"),
            withIntermediateDirectories: false)

        let error = #expect(throws: CodexOAuthCredentialsError.self) {
            try CodexOAuthCredentialsStore.loadOAuthTokens(env: ["CODEX_HOME": home.path])
        }
        guard case .unreadable = error else {
            Issue.record("Expected an unreadable auth path to remain distinguishable")
            return
        }
    }

    @Test
    func `malformed auth json maps to a safe decode error`() throws {
        let error = #expect(throws: CodexOAuthCredentialsError.self) {
            try CodexOAuthCredentialsStore.parse(data: Data("not-json".utf8))
        }
        guard case let .decodeFailed(message) = error else {
            Issue.record("Expected malformed JSON to map to decodeFailed")
            return
        }
        #expect(message == "Invalid JSON")
    }

    @Test
    func `missing account id falls back to the OpenAI JWT auth claim`() throws {
        let idToken = Self.jwt(payload: [
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-namespaced"],
        ])
        let data = try JSONSerialization.data(withJSONObject: [
            "tokens": [
                "access_token": "opaque-access",
                "refresh_token": "refresh",
                "id_token": idToken,
            ],
        ])

        let credentials = try CodexOAuthCredentialsStore.parse(data: data)

        #expect(credentials.accountId == "acct-namespaced")
    }

    @Test
    func `missing account id falls back to the direct OpenAI JWT claim`() throws {
        let idToken = Self.jwt(payload: [
            "chatgpt_account_id": "acct-direct",
        ])
        let data = try JSONSerialization.data(withJSONObject: [
            "tokens": [
                "access_token": "opaque-access",
                "refresh_token": "refresh",
                "id_token": idToken,
            ],
        ])

        let credentials = try CodexOAuthCredentialsStore.parse(data: data)

        #expect(credentials.accountId == "acct-direct")
    }

    @Test
    func `whitespace account id falls back to the OpenAI JWT claim`() throws {
        let accessToken = Self.jwt(payload: [
            "organizations": [["id": "org-from-jwt"]],
        ])
        let data = try JSONSerialization.data(withJSONObject: [
            "tokens": [
                "access_token": accessToken,
                "refresh_token": "refresh",
                "account_id": "  \n",
            ],
        ])

        let credentials = try CodexOAuthCredentialsStore.parse(data: data)

        #expect(credentials.accountId == "org-from-jwt")
    }

    @Test
    func `missing account id falls back to the first OpenAI organization`() throws {
        let accessToken = Self.jwt(payload: [
            "organizations": [["id": "org-first"], ["id": "org-second"]],
        ])
        let data = try JSONSerialization.data(withJSONObject: [
            "tokens": [
                "access_token": accessToken,
                "refresh_token": "refresh",
            ],
        ])

        let credentials = try CodexOAuthCredentialsStore.parse(data: data)

        #expect(credentials.accountId == "org-first")
    }

    @Test
    func `missing account id skips blank OpenAI organizations`() throws {
        let accessToken = Self.jwt(payload: [
            "organizations": [["id": "  "], ["id": "org-later"], ["id": ""]],
        ])
        let data = try JSONSerialization.data(withJSONObject: [
            "tokens": [
                "access_token": accessToken,
                "refresh_token": "refresh",
            ],
        ])

        let credentials = try CodexOAuthCredentialsStore.parse(data: data)

        #expect(credentials.accountId == "org-later")
    }

    @Test
    func `open code oauth credentials preserve expiry and remain read only`() throws {
        let expiresAt = Date().addingTimeInterval(3600)
        let payload: [String: Any] = [
            "openai": [
                "type": "oauth",
                "access": "open-code-access",
                "refresh": "open-code-refresh",
                "expires": Int(expiresAt.timeIntervalSince1970 * 1000),
                "accountId": "open-code-account",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let credentials = try CodexOAuthCredentialsStore._parseOpenCodeForTesting(data: data)

        #expect(credentials.accessToken == "open-code-access")
        #expect(credentials.refreshToken == "open-code-refresh")
        #expect(credentials.accountId == "open-code-account")
        #expect(credentials.source == .openCode)
        #expect(credentials.expiresAt.map { abs($0.timeIntervalSince(expiresAt)) < 1 } == true)
        #expect(!credentials.needsRefresh)
        let error = #expect(throws: CodexOAuthCredentialsError.self) {
            try CodexOAuthCredentialsStore.save(credentials, env: ["CODEX_HOME": "/tmp/unused-codex-home"])
        }
        guard case .readOnlySource = error else {
            Issue.record("OpenCode credentials must never be persisted by CodexBar")
            return
        }
    }

    @Test
    func `expired open code oauth credentials are marked for refresh`() throws {
        let payload: [String: Any] = [
            "openai": [
                "type": "oauth",
                "access": "expired-access",
                "refresh": "expired-refresh",
                "expires": Int(Date().addingTimeInterval(-1).timeIntervalSince1970 * 1000),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let credentials = try CodexOAuthCredentialsStore._parseOpenCodeForTesting(data: data)

        #expect(credentials.source == .openCode)
        #expect(credentials.needsRefresh)
    }

    @Test
    func `expired read-only oauth credentials fail closed without refresh`() async throws {
        let credentials = CodexOAuthCredentials(
            accessToken: "expired-access",
            refreshToken: "external-refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: nil,
            expiresAt: Date().addingTimeInterval(-1),
            source: .openCode)
        let error = await #expect(throws: CodexOAuthCredentialsError.self) {
            try await CodexOAuthFetchStrategy._prepareCredentialsForTesting(credentials)
        }
        guard case .readOnlySource = error else {
            Issue.record("Expired external credentials must not consume an owner refresh token")
            return
        }
    }

    @Test
    func `expired read-only oauth credentials without a refresh token are rejected`() async throws {
        let credentials = CodexOAuthCredentials(
            accessToken: "expired-access",
            refreshToken: "",
            idToken: nil,
            accountId: nil,
            lastRefresh: nil,
            expiresAt: Date().addingTimeInterval(-1),
            source: .legacyCodexHome)

        let error = await #expect(throws: CodexOAuthCredentialsError.self) {
            try await CodexOAuthFetchStrategy._prepareCredentialsForTesting(credentials)
        }
        guard case .readOnlySource = error else {
            Issue.record("Expired external credentials without a refresh token must fail closed")
            return
        }
    }

    @Test
    func `expired external oauth fetch fails closed without mutating its source`() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-stale-fetch-home-\(UUID().uuidString)", isDirectory: true)
        let dataHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-stale-fetch-data-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: dataHome)
        }
        let openCodeDirectory = dataHome.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: openCodeDirectory, withIntermediateDirectories: true)
        let authData = Data(
            #"{"openai":{"type":"oauth","access":"expired-access","refresh":"external-refresh","expires":1}}"#
                .utf8)
        let authURL = openCodeDirectory.appendingPathComponent("auth.json")
        try authData.write(to: authURL)
        let credentials = try CodexOAuthCredentialsStore._loadForUsageForTesting(
            env: ["XDG_DATA_HOME": dataHome.path],
            homeDirectory: home,
            allowExternalSources: true)
        let error = await #expect(throws: CodexOAuthCredentialsError.self) {
            try await CodexOAuthFetchStrategy._prepareCredentialsForTesting(
                credentials,
                env: ["XDG_DATA_HOME": dataHome.path])
        }
        guard case .readOnlySource = error else {
            Issue.record("Expired external credentials must fail closed")
            return
        }
        #expect(try Data(contentsOf: authURL) == authData)
    }

    @Test
    func `valid read-only oauth credentials pass through without refresh`() async throws {
        let credentials = CodexOAuthCredentials(
            accessToken: "valid-access",
            refreshToken: "external-refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            source: .openCode)
        let resolved = try await CodexOAuthFetchStrategy._prepareCredentialsForTesting(credentials)

        #expect(resolved.accessToken == "valid-access")
        #expect(resolved.source == .openCode)
    }

    @Test
    func `managed workspace metadata supplies the account header without rewriting auth`() async throws {
        let credentials = CodexOAuthCredentials(
            accessToken: "valid-access",
            refreshToken: "refresh",
            idToken: nil,
            accountId: "auth-account",
            lastRefresh: Date(),
            source: .codexHome)
        let settings = ProviderSettingsSnapshot.make(codex: CodexProviderSettings(
            usageDataSource: .oauth,
            cookieSource: .off,
            manualCookieHeader: nil,
            managedWorkspaceAccountID: "workspace-team"))
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "workspace-team")
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: nil,
                      headerFields: nil)
            else { throw URLError(.badURL) }
            let body = #"""
            {"rate_limit":{"primary_window":{"used_percent":4,"reset_at":1786161204,"limit_window_seconds":18000}}}
            """#
            return (Data(body.utf8), response)
        }

        let result = try await CodexAuthenticatedHTTPTransport.$overrideForTesting.withValue(transport) {
            try await CodexOAuthFetchStrategy._fetchForTesting(
                context: Self.context(settings: settings),
                credentials: credentials)
        }

        #expect(result.usage.primary?.usedPercent == 4)
    }

    @Test
    func `expired native oauth credentials delegate refresh to the Codex CLI`() async throws {
        let credentials = CodexOAuthCredentials(
            accessToken: "expired-access",
            refreshToken: "native-refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date(timeIntervalSince1970: 0),
            source: .codexHome)
        let error = await #expect(throws: CodexOAuthCredentialsError.self) {
            try await CodexOAuthFetchStrategy._prepareCredentialsForTesting(
                credentials,
                env: ["CODEX_HOME": "/tmp/codexbar-native-refresh-memory"])
        }
        guard case .nativeRefreshRequired = error else {
            Issue.record("Native stale credentials must be handed to Codex CLI")
            return
        }
    }

    @Test
    func `stale native probes never redeem a shared refresh token`() async throws {
        let credentials = CodexOAuthCredentials(
            accessToken: "expired-access",
            refreshToken: "native-refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date(timeIntervalSince1970: 0),
            source: .codexHome)
        let first = await #expect(throws: CodexOAuthCredentialsError.self) {
            try await CodexOAuthFetchStrategy._prepareCredentialsForTesting(credentials)
        }
        let second = await #expect(throws: CodexOAuthCredentialsError.self) {
            try await CodexOAuthFetchStrategy._prepareCredentialsForTesting(credentials)
        }
        guard case .nativeRefreshRequired = first,
              case .nativeRefreshRequired = second
        else {
            Issue.record("Every stale native probe must hand refresh to Codex CLI")
            return
        }
    }

    @Test
    func `consented external OAuth fetch uses the token without mutating its source`() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-fetch-home-\(UUID().uuidString)", isDirectory: true)
        let dataHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-fetch-data-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: dataHome)
        }
        let openCodeDirectory = dataHome.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: openCodeDirectory, withIntermediateDirectories: true)
        let authData = Data(#"""
        {"openai":{"type":"oauth","access":"external-access","refresh":"external-refresh","expires":4102444800000}}
        """#.utf8)
        let authURL = openCodeDirectory.appendingPathComponent("auth.json")
        try authData.write(to: authURL)

        let credentials = try CodexOAuthCredentialsStore._loadForUsageForTesting(
            env: ["XDG_DATA_HOME": dataHome.path],
            homeDirectory: home,
            allowExternalSources: true)
        let settings = ProviderSettingsSnapshot.make(codex: CodexProviderSettings(
            usageDataSource: .oauth,
            cookieSource: .off,
            manualCookieHeader: nil,
            allowExternalOAuthSources: true))
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer external-access")
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: nil,
                      headerFields: nil)
            else {
                throw URLError(.badURL)
            }
            let body = #"""
            {"rate_limit":{"primary_window":{"used_percent":12,"reset_at":1786161204,
            "limit_window_seconds":18000},"secondary_window":null}}
            """#
            return (Data(body.utf8), response)
        }

        let result = try await CodexAuthenticatedHTTPTransport.$overrideForTesting
            .withValue(transport) {
                try await CodexOAuthFetchStrategy._fetchForTesting(
                    context: Self.context(
                        env: ["XDG_DATA_HOME": dataHome.path],
                        settings: settings),
                    credentials: credentials)
            }

        #expect(result.usage.primary?.usedPercent == 12)
        #expect(try Data(contentsOf: authURL) == authData)
    }

    @Test
    func `open code api credentials are not accepted as oauth`() throws {
        let payload: [String: Any] = [
            "openai": [
                "type": "api",
                "key": "open-code-api-key",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let error = #expect(throws: CodexOAuthCredentialsError.self) {
            try CodexOAuthCredentialsStore._parseOpenCodeForTesting(data: data)
        }
        guard case .missingTokens = error else {
            Issue.record("OpenCode API-key entries must not be treated as OAuth credentials")
            return
        }
    }

    @Test
    func `credential save preserves the supplied refresh timestamp`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-save-timestamp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try CodexOAuthCredentialsStore.save(
            CodexOAuthCredentials(
                accessToken: "access",
                refreshToken: "refresh",
                idToken: nil,
                accountId: "account",
                lastRefresh: timestamp),
            env: ["CODEX_HOME": home.path])

        let data = try Data(contentsOf: home.appendingPathComponent("auth.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rawTimestamp = try #require(json["last_refresh"] as? String)
        let parsed = try #require(ISO8601DateFormatter().date(from: rawTimestamp))
        #expect(abs(parsed.timeIntervalSince(timestamp)) < 0.001)
    }

    private static func context(
        env: [String: String] = [:],
        settings: ProviderSettingsSnapshot? = nil) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .oauth,
            includeCredits: false,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: settings,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    @Test
    func `native codex home wins over external oauth sources`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-native-home-\(UUID().uuidString)", isDirectory: true)
        let dataHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-native-data-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: dataHome)
        }

        let nativeDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        let openCodeDirectory = dataHome.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: nativeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: openCodeDirectory, withIntermediateDirectories: true)

        let native = """
        {
          "tokens": {
            "access_token": "native-access",
            "refresh_token": "native-refresh"
          }
        }
        """
        try Data(native.utf8).write(to: nativeDirectory.appendingPathComponent("auth.json"))
        let external: [String: Any] = [
            "openai": ["type": "oauth", "access": "external-access"],
        ]
        try JSONSerialization.data(withJSONObject: external)
            .write(to: openCodeDirectory.appendingPathComponent("auth.json"))

        let credentials = try CodexOAuthCredentialsStore._loadForUsageForTesting(
            env: ["XDG_DATA_HOME": dataHome.path],
            homeDirectory: home,
            allowExternalSources: true)

        #expect(credentials.source == .codexHome)
        #expect(credentials.accessToken == "native-access")
    }

    @Test
    func `legacy codex home wins before open code fallback`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-legacy-home-\(UUID().uuidString)", isDirectory: true)
        let dataHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-legacy-data-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: dataHome)
        }

        let legacyDirectory = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
        let openCodeDirectory = dataHome.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: openCodeDirectory, withIntermediateDirectories: true)

        let legacy = """
        {
          "tokens": {
            "access_token": "legacy-access",
            "refresh_token": "legacy-refresh"
          }
        }
        """
        try Data(legacy.utf8).write(to: legacyDirectory.appendingPathComponent("auth.json"))
        let external: [String: Any] = [
            "openai": ["type": "oauth", "access": "external-access"],
        ]
        try JSONSerialization.data(withJSONObject: external)
            .write(to: openCodeDirectory.appendingPathComponent("auth.json"))

        let credentials = try CodexOAuthCredentialsStore._loadForUsageForTesting(
            env: ["XDG_DATA_HOME": dataHome.path],
            homeDirectory: home,
            allowExternalSources: true)

        #expect(credentials.source == .legacyCodexHome)
        #expect(credentials.accessToken == "legacy-access")
    }

    @Test
    func `legacy API keys are rejected by the external OAuth fallback`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-legacy-api-key-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let legacyDirectory = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacy = #"{"OPENAI_API_KEY":"legacy-api-key"}"#
        try Data(legacy.utf8).write(to: legacyDirectory.appendingPathComponent("auth.json"))

        let error = #expect(throws: CodexOAuthCredentialsError.self) {
            try CodexOAuthCredentialsStore._loadForUsageForTesting(
                env: [:],
                homeDirectory: home,
                allowExternalSources: true)
        }
        guard case .notFound = error else {
            Issue.record("External legacy API keys must not be treated as OAuth credentials")
            return
        }
    }

    @Test
    func `usage credential loading falls back to isolated open code data`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-fallback-home-\(UUID().uuidString)", isDirectory: true)
        let dataHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-fallback-data-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: dataHome)
        }
        let openCodeDirectory = dataHome.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: openCodeDirectory, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "openai": [
                "type": "oauth",
                "access": "fallback-access",
                "refresh": "fallback-refresh",
                "expires": Int(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: openCodeDirectory.appendingPathComponent("auth.json"))

        let credentials = try CodexOAuthCredentialsStore._loadForUsageForTesting(
            env: ["XDG_DATA_HOME": dataHome.path],
            homeDirectory: home,
            allowExternalSources: true)

        #expect(credentials.source == .openCode)
        #expect(credentials.accessToken == "fallback-access")
    }

    @Test
    func `external fallback does not mask an unreadable native auth file`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-unreadable-native-\(UUID().uuidString)", isDirectory: true)
        let dataHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-unreadable-external-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: dataHome)
        }
        let nativeDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        let openCodeDirectory = dataHome.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: nativeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: nativeDirectory.appendingPathComponent("auth.json"),
            withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: openCodeDirectory, withIntermediateDirectories: true)
        try Data(#"{"openai":{"type":"oauth","access":"must-not-mask-native-read-error"}}"#.utf8)
            .write(to: openCodeDirectory.appendingPathComponent("auth.json"))

        let error = #expect(throws: CodexOAuthCredentialsError.self) {
            try CodexOAuthCredentialsStore._loadForUsageForTesting(
                env: ["XDG_DATA_HOME": dataHome.path],
                homeDirectory: home,
                allowExternalSources: true)
        }
        guard case .unreadable = error else {
            Issue.record("An unreadable native file must not be replaced by another app's OAuth session")
            return
        }
    }

    @Test
    func `external fallback does not mask malformed native auth json`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-malformed-native-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let nativeDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: nativeDirectory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: nativeDirectory.appendingPathComponent("auth.json"))

        let error = #expect(throws: CodexOAuthCredentialsError.self) {
            try CodexOAuthCredentialsStore._loadForUsageForTesting(
                env: [:],
                homeDirectory: home,
                allowExternalSources: true)
        }
        guard case .decodeFailed = error else {
            Issue.record("Malformed native auth JSON must remain a decode failure")
            return
        }
    }

    @Test
    func `external fallback does not mask native auth without oauth tokens`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-missing-tokens-native-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let nativeDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: nativeDirectory, withIntermediateDirectories: true)
        try Data(#"{"tokens":{}}"#.utf8).write(to: nativeDirectory.appendingPathComponent("auth.json"))

        let error = #expect(throws: CodexOAuthCredentialsError.self) {
            try CodexOAuthCredentialsStore._loadForUsageForTesting(
                env: [:],
                homeDirectory: home,
                allowExternalSources: true)
        }
        guard case .missingTokens = error else {
            Issue.record("Native auth without OAuth tokens must not silently borrow another source")
            return
        }
    }

    @Test
    func `external OAuth fallback is disabled without explicit consent`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-consent-home-\(UUID().uuidString)", isDirectory: true)
        let dataHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-consent-data-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: dataHome)
        }
        let openCodeDirectory = dataHome.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: openCodeDirectory, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "openai": ["type": "oauth", "access": "must-not-be-read"],
        ]
        try JSONSerialization.data(withJSONObject: payload)
            .write(to: openCodeDirectory.appendingPathComponent("auth.json"))

        let error = #expect(throws: CodexOAuthCredentialsError.self) {
            try CodexOAuthCredentialsStore._loadForUsageForTesting(
                env: ["XDG_DATA_HOME": dataHome.path],
                homeDirectory: home)
        }
        guard case .notFound = error else {
            Issue.record("External OAuth files require explicit consent before they are read")
            return
        }
    }

    @Test
    func `explicit codex home does not borrow open code credentials`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-isolated-home-\(UUID().uuidString)", isDirectory: true)
        let dataHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-isolated-data-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: dataHome)
        }
        let openCodeDirectory = dataHome.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: openCodeDirectory, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "openai": ["type": "oauth", "access": "should-not-be-used"],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: openCodeDirectory.appendingPathComponent("auth.json"))

        let error = #expect(throws: CodexOAuthCredentialsError.self) {
            try CodexOAuthCredentialsStore._loadForUsageForTesting(
                env: ["CODEX_HOME": home.path, "XDG_DATA_HOME": dataHome.path],
                homeDirectory: home)
        }
        guard case .notFound = error else {
            Issue.record("An explicit CODEX_HOME must not borrow an OpenCode credential")
            return
        }
    }

    private static func jwt(payload: [String: Any]) -> String {
        let encode: (Data) -> String = { data in
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = encode(Data(#"{"alg":"none","typ":"JWT"}"#.utf8))
        let body = (try? JSONSerialization.data(withJSONObject: payload)).map(encode) ?? ""
        return "\(header).\(body).signature"
    }
}
