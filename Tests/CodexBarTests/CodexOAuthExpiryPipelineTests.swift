import Foundation
import Testing
@testable import CodexBarCore

@Suite(CodexCredentialFixtures())
struct CodexOAuthExpiryPipelineTests {
    @Test(arguments: [ProviderSourceMode.auto, .oauth], [false, true])
    func `future expiry keeps OAuth model windows and account scope despite old refresh age`(
        mode: ProviderSourceMode,
        managed: Bool) async throws
    {
        let fixture = try Self.fixture(expiration: 4_102_444_800, lastRefresh: "2000-01-01T00:00:00Z")
        let context = Self.context(mode: mode, managed: managed, home: fixture.home)
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/backend-api/wham/usage")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fixture.token)")
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id")
                == (managed ? "fixture-workspace" : "fixture-account"))
            return try Self.response(request, body: Self.usageBody)
        }
        let outcome = await CodexAuthenticatedHTTPTransport.$overrideForTesting.withValue(transport) {
            await Self.pipeline.fetch(context: context, provider: .codex)
        }
        let result = try outcome.result.get()
        #expect(result.strategyID == "codex.oauth")
        #expect(result.usage.primary?.usedPercent == 22)
        #expect(result.usage.secondary?.usedPercent == 43)
        #expect(result.usage.extraRateWindows?.map(\.id) == ["codex-spark", "codex-spark-weekly"])
        #expect(result.usage.extraRateWindows?.map(\.window.usedPercent) == [30, 80])
        #expect(outcome.attempts.filter(\.wasAvailable).map(\.strategyID) == ["codex.oauth"])
        #expect(await transport.requests().count == 1)
        try fixture.expectUnchanged()
    }

    @Test(arguments: [ProviderSourceMode.auto, .oauth], [false, true])
    func `expired and near expiry native tokens retain CLI ownership and managed scope`(
        mode: ProviderSourceMode,
        managed: Bool) async throws
    {
        for offset in [-60.0, 120] {
            let fixture = try Self.fixture(
                expiration: Int64(Date().timeIntervalSince1970 + offset),
                lastRefresh: ISO8601DateFormatter().string(from: Date()))
            let context = Self.context(mode: mode, managed: managed, home: fixture.home)
            let transport = ProviderHTTPTransportStub { _ in
                Issue.record("Stale native credentials must not make a usage or refresh request")
                throw URLError(.cancelled)
            }
            let recovery = CodexOAuthNativeRefreshCLIStrategy(binaryResolver: { _ in "/fixture/codex" })
            #expect(await recovery.isAvailable(context))
            let outcome = await CodexAuthenticatedHTTPTransport.$overrideForTesting.withValue(transport) {
                await Self.pipeline.fetch(context: context, provider: .codex)
            }
            guard case let .failure(error) = outcome.result, error is CLISelected else {
                Issue.record("Native refresh must be handed to the credential-owning CLI")
                continue
            }
            let expectedRecoveryID = managed || mode == .oauth
                ? "codex.oauth-native-refresh-cli"
                : "codex.cli"
            #expect(outcome.attempts.last?.strategyID == expectedRecoveryID)
            #expect(await transport.requests().isEmpty)
            try fixture.expectUnchanged()
        }
    }

    @Test(arguments: ["401", "403", "500", "decode", "network"], ["auto", "oauth", "managed-auto", "managed-oauth"])
    func `unverified future expiry retains unauthorized and transient failure contracts`(
        failure: String,
        scenario: String) async throws
    {
        let fixture = try Self.fixture(expiration: 4_102_444_800, lastRefresh: "2000-01-01T00:00:00Z")
        let mode: ProviderSourceMode = scenario.hasSuffix("auto") ? .auto : .oauth
        let managed = scenario.hasPrefix("managed")
        let context = Self.context(mode: mode, managed: managed, home: fixture.home)
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fixture.token)")
            if failure == "network" { throw URLError(.timedOut) }
            return try Self.response(request, code: Int(failure) ?? 200, body: "not-json")
        }
        let outcome = await CodexAuthenticatedHTTPTransport.$overrideForTesting.withValue(transport) {
            await Self.pipeline.fetch(context: context, provider: .codex)
        }
        let unauthorized = failure == "401"
        let forbidden = failure == "403"
        let expectsCLI = unauthorized
        guard case let .failure(error) = outcome.result else {
            Issue.record("An expiry hint cannot authenticate a rejected token")
            return
        }
        if expectsCLI {
            #expect(error is CLISelected)
            let expectedRecoveryID = managed || mode == .oauth
                ? "codex.oauth-native-refresh-cli"
                : "codex.cli"
            #expect(outcome.attempts.last?.strategyID == expectedRecoveryID)
        } else {
            let oauthError = try #require(error as? CodexOAuthFetchError)
            switch oauthError {
            case .unauthorized: #expect(unauthorized)
            case .forbidden: #expect(forbidden)
            case .serverError: #expect(failure == "500")
            case .invalidResponse: #expect(failure == "decode")
            case .networkError: #expect(failure == "network")
            }
            #expect(outcome.attempts.filter { $0.kind == .cli && $0.wasAvailable }.isEmpty)
        }
        #expect(await transport.requests().count == 1)
        try fixture.expectUnchanged()
    }

    @Test(arguments: [ProviderSourceMode.auto, .oauth], [CodexOAuthCredentialSource.legacyCodexHome, .openCode])
    func `stale external credentials never reach transport or CLI recovery`(
        mode: ProviderSourceMode,
        source: CodexOAuthCredentialSource) async throws
    {
        let home = CodexCredentialFixtures.root
        let directory = home
            .appendingPathComponent(source == .legacyCodexHome ? ".config/codex" : ".local/share/opencode")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = Data(#"{"exp":4102444800}"#.utf8).base64EncodedString()
        let token = "fixture.\(payload).signature"
        let json: [String: Any] = source == .legacyCodexHome
            ? [
                "tokens": ["access_token": token, "refresh_token": "fixture-refresh"],
                "last_refresh": "2000-01-01T00:00:00Z",
            ]
            : [
                "openai": [
                    "type": "oauth", "access": token, "refresh": "fixture-refresh",
                    "expires": Int64((Date().timeIntervalSince1970 + 30) * 1000),
                ] as [String: Any],
            ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let url = directory.appendingPathComponent("auth.json")
        try data.write(to: url)
        let credentials = try CodexOAuthCredentialsStore._loadForUsageForTesting(
            env: [:], homeDirectory: home, allowExternalSources: true)
        #expect(credentials.source == source)
        let context = Self.context(mode: mode, managed: false, home: home)
        // The loader seam selects external files under the synthetic home; fetch and fallback
        // still use production OAuth behavior with that exact credential snapshot.
        let pipeline = ProviderFetchPipeline { _ in
            [ExternalSnapshotStrategy(credentials: credentials), CLISelectionProbe(id: "codex.cli")]
        }
        let transport = ProviderHTTPTransportStub { _ in
            Issue.record("Read-only stale credentials must never make a usage or refresh request")
            throw URLError(.cancelled)
        }
        let outcome = await CodexAuthenticatedHTTPTransport.$overrideForTesting.withValue(transport) {
            await pipeline.fetch(context: context, provider: .codex)
        }
        guard case let .failure(error) = outcome.result,
              case .readOnlySource = error as? CodexOAuthCredentialsError
        else {
            Issue.record("External sources must fail closed")
            return
        }
        #expect(outcome.attempts.map(\.strategyID) == ["codex.oauth"])
        #expect(await transport.requests().isEmpty)
        #expect(try Data(contentsOf: url) == data)
    }

    private struct ExternalSnapshotStrategy: ProviderFetchStrategy {
        let credentials: CodexOAuthCredentials
        let id = "codex.oauth"
        let kind: ProviderFetchKind = .oauth

        func isAvailable(_: ProviderFetchContext) async -> Bool {
            true
        }

        func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
            try await CodexOAuthFetchStrategy._fetchForTesting(context: context, credentials: self.credentials)
        }

        func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
            CodexOAuthFetchStrategy().shouldFallback(on: error, context: context)
        }
    }

    /// Keep production selection, availability, OAuth file loading, mapping and fallback policy.
    /// Only the actual CLI process is replaced with a sentinel to make recovery observable and offline.
    private static let pipeline = ProviderFetchPipeline { context in
        let strategies = await CodexProviderDescriptor.descriptor.fetchPlan.pipeline.resolveStrategies(context)
        return strategies.map { strategy -> any ProviderFetchStrategy in
            strategy.kind == .cli ? CLISelectionProbe(id: strategy.id) : strategy
        }
    }

    private struct CLISelected: Error {}

    private struct CLISelectionProbe: ProviderFetchStrategy {
        let id: String
        let kind: ProviderFetchKind = .cli

        func isAvailable(_ context: ProviderFetchContext) async -> Bool {
            if self.id == "codex.oauth-native-refresh-cli" {
                return await CodexOAuthNativeRefreshCLIStrategy(binaryResolver: { _ in "/fixture/codex" })
                    .isAvailable(context)
            }
            return true
        }

        func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
            throw CLISelected()
        }

        func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
            false
        }
    }

    private struct Fixture {
        let home: URL
        let token: String
        let data: Data
        let modificationDate: Date
        let fileNumber: UInt64

        func expectUnchanged() throws {
            let url = self.home.appendingPathComponent("auth.json")
            #expect(try Data(contentsOf: url) == self.data)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect(attributes[.modificationDate] as? Date == self.modificationDate)
            #expect((attributes[.systemFileNumber] as? NSNumber)?.uint64Value == self.fileNumber)
        }
    }

    private static func fixture(expiration: Int64, lastRefresh: String) throws -> Fixture {
        let home = CodexCredentialFixtures.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let payload = Data(#"{"exp":\#(expiration)}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "fixture.\(payload).signature"
        let data = try JSONSerialization.data(withJSONObject: [
            "tokens": ["access_token": token, "refresh_token": "fixture-refresh", "account_id": "fixture-account"],
            "last_refresh": lastRefresh,
        ])
        let url = home.appendingPathComponent("auth.json")
        try data.write(to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try Fixture(
            home: home,
            token: token,
            data: data,
            modificationDate: #require(attributes[.modificationDate] as? Date),
            fileNumber: #require(attributes[.systemFileNumber] as? NSNumber).uint64Value)
    }

    private static func context(mode: ProviderSourceMode, managed: Bool, home: URL) -> ProviderFetchContext {
        let env = ["CODEX_HOME": home.path, "HOME": CodexCredentialFixtures.root.path, "PATH": ""]
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: mode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: ProviderSettingsSnapshot.make(codex: CodexProviderSettings(
                usageDataSource: mode == .auto ? .auto : .oauth,
                cookieSource: .off,
                manualCookieHeader: nil,
                managedWorkspaceAccountID: managed ? "fixture-workspace" : nil)),
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    private static func response(
        _ request: URLRequest,
        code: Int = 200,
        body: String) throws -> (Data, URLResponse)
    {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: code, httpVersion: nil, headerFields: nil))
        return (Data(body.utf8), response)
    }

    private static let usageBody = #"""
    {
      "plan_type":"pro",
      "rate_limit":{
        "primary_window":{"used_percent":22,"reset_at":4102444800,"limit_window_seconds":18000},
        "secondary_window":{"used_percent":43,"reset_at":4102444800,"limit_window_seconds":604800}
      },
      "additional_rate_limits":[{
        "limit_name":"GPT-5.3-Codex-Spark",
        "metered_feature":"gpt_5_3_codex_spark",
        "rate_limit":{
          "primary_window":{"used_percent":30,"reset_at":4102444800,"limit_window_seconds":18000},
          "secondary_window":{"used_percent":80,"reset_at":4102444800,"limit_window_seconds":604800}
        }
      }]
    }
    """#
}
