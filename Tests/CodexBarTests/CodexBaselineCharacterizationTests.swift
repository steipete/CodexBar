import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CodexBaselineCharacterizationTests {
    private func makeContext(
        runtime: ProviderRuntime,
        sourceMode: ProviderSourceMode,
        env: [String: String] = [:],
        settings: ProviderSettingsSnapshot? = nil) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: runtime,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: settings,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    private func strategyIDs(
        runtime: ProviderRuntime,
        sourceMode: ProviderSourceMode,
        env: [String: String] = [:],
        settings: ProviderSettingsSnapshot? = nil) async -> [String]
    {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .codex)
        let context = self.makeContext(runtime: runtime, sourceMode: sourceMode, env: env, settings: settings)
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)
        return strategies.map(\.id)
    }

    private func fetchOutcome(
        runtime: ProviderRuntime,
        sourceMode: ProviderSourceMode,
        env: [String: String] = [:],
        settings: ProviderSettingsSnapshot? = nil) async -> ProviderFetchOutcome
    {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .codex)
        let context = self.makeContext(runtime: runtime, sourceMode: sourceMode, env: env, settings: settings)
        return await descriptor.fetchPlan.fetchOutcome(context: context, provider: .codex)
    }

    private func makeStubCodexCLI() throws -> String {
        let script = """
        #!/usr/bin/python3
        import json
        import sys

        for line in sys.stdin:
            if not line.strip():
                continue
            message = json.loads(line)
            method = message.get("method")
            if method == "initialized":
                continue

            identifier = message.get("id")
            if method == "initialize":
                payload = {"id": identifier, "result": {}}
            elif method == "account/rateLimits/read":
                payload = {
                    "id": identifier,
                    "result": {
                        "rateLimits": {
                            "primary": {
                                "usedPercent": 12,
                                "windowDurationMins": 300,
                                "resetsAt": 1766948068
                            },
                            "secondary": {
                                "usedPercent": 43,
                                "windowDurationMins": 10080,
                                "resetsAt": 1767407914
                            },
                            "credits": {
                                "hasCredits": True,
                                "unlimited": False,
                                "balance": "7"
                            }
                        }
                    }
                }
            elif method == "account/read":
                payload = {
                    "id": identifier,
                    "result": {
                        "account": {
                            "type": "chatgpt",
                            "email": "stub@example.com",
                            "planType": "pro"
                        },
                        "requiresOpenaiAuth": False
                    }
                }
            else:
                payload = {"id": identifier, "result": {}}

            print(json.dumps(payload), flush=True)
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-stub-\(UUID().uuidString)", isDirectory: false)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func makeEmptyCodexHome() throws -> URL {
        let homeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-empty-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        return homeURL
    }

    private func makeUnavailableOAuthHome() throws -> URL {
        let homeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-oauth-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)

        let credentials = CodexOAuthCredentials(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: nil,
            accountId: "account-id",
            lastRefresh: Date())
        try CodexOAuthCredentialsStore.save(credentials, env: ["CODEX_HOME": homeURL.path])

        let configURL = homeURL.appendingPathComponent("config.toml")
        try "chatgpt_base_url = \"http://127.0.0.1:9\"".write(to: configURL, atomically: true, encoding: .utf8)

        return homeURL
    }

    @Test
    func `app auto pipeline order is OAuth then CLI without web`() async {
        let strategyIDs = await self.strategyIDs(runtime: .app, sourceMode: .auto)
        #expect(strategyIDs == ["codex.oauth", "codex.cli"])
    }

    @Test
    func `CLI auto pipeline order is web then CLI`() async {
        let strategyIDs = await self.strategyIDs(runtime: .cli, sourceMode: .auto)
        #expect(strategyIDs == ["codex.web.dashboard", "codex.cli"])
    }

    @Test
    func `explicit fetch plan modes keep single Codex strategy selection`() async {
        let appCases: [(ProviderSourceMode, [String])] = [
            (.oauth, ["codex.oauth"]),
            (.cli, ["codex.cli"]),
            (.web, ["codex.web.dashboard"]),
        ]

        for (sourceMode, expected) in appCases {
            let strategyIDs = await self.strategyIDs(runtime: .app, sourceMode: sourceMode)
            #expect(strategyIDs == expected)
        }

        for (sourceMode, expected) in appCases {
            let strategyIDs = await self.strategyIDs(runtime: .cli, sourceMode: sourceMode)
            #expect(strategyIDs == expected)
        }
    }

    @Test
    func `app auto records unavailable OAuth before successful CLI fallback`() async throws {
        let stubCLIPath = try self.makeStubCodexCLI()
        let codexHome = try self.makeEmptyCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        let env = [
            "CODEX_CLI_PATH": stubCLIPath,
            "CODEX_HOME": codexHome.path,
        ]

        let outcome = await self.fetchOutcome(runtime: .app, sourceMode: .auto, env: env)

        #expect(outcome.attempts.map(\.strategyID) == ["codex.oauth", "codex.cli"])
        #expect(outcome.attempts.map(\.wasAvailable) == [false, true])

        switch outcome.result {
        case let .success(result):
            #expect(result.sourceLabel == "codex-cli")
            #expect(result.usage.accountEmail(for: .codex) == "stub@example.com")
            #expect(result.usage.loginMethod(for: .codex) == "pro")
        case let .failure(error):
            Issue.record("Unexpected failure: \(error)")
        }
    }

    @Test
    func `app auto falls back from failing OAuth to successful CLI`() async throws {
        let stubCLIPath = try self.makeStubCodexCLI()
        let oauthHome = try self.makeUnavailableOAuthHome()
        defer { try? FileManager.default.removeItem(at: oauthHome) }

        let env = [
            "CODEX_CLI_PATH": stubCLIPath,
            "CODEX_HOME": oauthHome.path,
        ]

        let outcome = await self.fetchOutcome(runtime: .app, sourceMode: .auto, env: env)

        #expect(outcome.attempts.map(\.strategyID) == ["codex.oauth", "codex.cli"])
        #expect(outcome.attempts.map(\.wasAvailable) == [true, true])
        #expect(outcome.attempts[0].errorDescription?.isEmpty == false)
        #expect(outcome.attempts[1].errorDescription == nil)

        switch outcome.result {
        case let .success(result):
            #expect(result.sourceLabel == "codex-cli")
            #expect(result.usage.primary?.windowMinutes == 300)
            #expect(result.usage.secondary?.windowMinutes == 10080)
        case let .failure(error):
            Issue.record("Unexpected failure: \(error)")
        }
    }

    @Test
    func `CLI auto records unavailable web before successful CLI`() async throws {
        let stubCLIPath = try self.makeStubCodexCLI()
        let env = ["CODEX_CLI_PATH": stubCLIPath]
        let settings = ProviderSettingsSnapshot.make(
            codex: .init(
                usageDataSource: .auto,
                cookieSource: .auto,
                manualCookieHeader: nil,
                managedAccountStoreUnreadable: true))

        let outcome = await self.fetchOutcome(runtime: .cli, sourceMode: .auto, env: env, settings: settings)

        #expect(outcome.attempts.map(\.strategyID) == ["codex.web.dashboard", "codex.cli"])
        #expect(outcome.attempts.map(\.wasAvailable) == [false, true])

        switch outcome.result {
        case let .success(result):
            #expect(result.sourceLabel == "codex-cli")
            #expect(result.usage.accountEmail(for: .codex) == "stub@example.com")
        case let .failure(error):
            Issue.record("Unexpected failure: \(error)")
        }
    }
}
