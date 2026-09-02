import Foundation
import Testing
@testable import CodexBarCore

struct GrokAccountContextTests {
    @Test
    func `billing retains account A when auth is replaced while suspended`() async throws {
        let fixture = try GrokAccountFixture()
        defer { fixture.remove() }
        try fixture.write(account: "a")
        let gate = GrokBillingGate()
        let context = fixture.context()
        let task = Task {
            try await GrokWebFetchStrategy.isolated.fetch(context) { capturedCredentials in
                let credentials = try capturedCredentials.get()
                #expect(credentials.accessToken == "fake-token-a")
                await gate.suspend()
                return GrokWebBillingResult(
                    snapshot: GrokWebBillingSnapshot(usedPercent: 37, resetsAt: nil),
                    sourceLabel: "grok-cli-proxy",
                    authContext: .oauth(credentials))
            } settingsTier: { credentials in
                #expect(credentials?.accessToken == "fake-token-a")
                #expect(credentials?.email == "a@example.com")
                return "SuperGrok Heavy"
            }
        }
        await gate.waitUntilSuspended()
        let replacement = Result { try fixture.write(account: "b") }
        await gate.resume()
        let result = try await task.value
        try replacement.get()

        #expect(result.usage.primary?.usedPercent == 37)
        #expect(result.usage.accountEmail(for: .grok) == "a@example.com")
        #expect(result.usage.accountOrganization(for: .grok) == "team-a")
        #expect(result.usage.loginMethod(for: .grok) == "SuperGrok Heavy")
    }

    @Test(arguments: [GrokOAuthFetchStrategy.Mode.proxyThenGrpc, .proxy, .grpc])
    func `oauth modes share exactly one raw capture across billing identity and tier`(
        mode: GrokOAuthFetchStrategy.Mode) async throws
    {
        let fixture = try GrokAccountFixture()
        defer { fixture.remove() }
        try fixture.write(account: "a")
        let reads = LockIsolated(0)
        let gate = GrokBillingGate()
        var webStrategy = GrokWebFetchStrategy.isolated
        webStrategy.loadCredentials = { context in
            reads.setValue(reads.value + 1)
            return Result {
                let credentials = try GrokWebFetchStrategy.resolvedCredentialsResult(context: context).get()
                // A second ambient capture at either owner boundary would now select B.
                try fixture.write(account: "b")
                return credentials
            }
        }
        let billing: GrokWebFetchStrategy.ProxyBillingFetch = { credentials in
            Self.expectAccountA(credentials)
            await gate.suspend()
            return GrokWebBillingSnapshot(usedPercent: 37, resetsAt: nil)
        }
        let strategy = GrokOAuthFetchStrategy(
            mode: mode,
            proxyBilling: billing,
            grpcBilling: billing,
            webStrategy: webStrategy,
            settingsTier: { credentials in
                Self.expectAccountA(credentials)
                return "SuperGrok Heavy"
            })
        let task = Task { try await strategy.fetch(fixture.context()) }
        await gate.waitUntilSuspended()
        let replacement = Result { try fixture.write(account: "c") }
        await gate.resume()
        let result = try await task.value
        try replacement.get()

        #expect(reads.value == 1)
        #expect(result.usage.primary?.usedPercent == 37)
        #expect(result.usage.accountEmail(for: .grok) == "a@example.com")
        #expect(result.usage.accountOrganization(for: .grok) == "team-a")
        #expect(result.usage.loginMethod(for: .grok) == "SuperGrok Heavy")
        #expect(result.sourceLabel == (mode == .grpc ? "grok-web" : "grok-cli-proxy"))
    }

    @Test(arguments: [false, true])
    func `cookie success stays siloed while team rejection retains only captured metadata`(
        teamRejection: Bool) async throws
    {
        let fixture = try GrokAccountFixture()
        defer { fixture.remove() }
        try fixture.write(account: "a", principal: "Team")
        let gate = GrokBillingGate()
        let tierCalls = LockIsolated(0)
        let task = Task {
            try await GrokWebFetchStrategy.isolated.fetch(fixture.context(sourceMode: .web)) { _ in
                await gate.suspend()
                if teamRejection { throw GrokWebBillingError.teamUsageUnsupported }
                return GrokWebBillingResult(
                    snapshot: GrokWebBillingSnapshot(
                        usedPercent: 23,
                        resetsAt: nil,
                        subscriptionTier: "Cookie Plan"),
                    sourceLabel: "manual-cookie",
                    authContext: .cookie("sso=test"))
            } settingsTier: { credentials in
                tierCalls.setValue(tierCalls.value + 1)
                Self.expectAccountA(credentials)
                return "SuperGrok Heavy"
            }
        }
        await gate.waitUntilSuspended()
        let replacement = Result { try fixture.write(account: "b", principal: "Team") }
        await gate.resume()
        let result = try await task.value
        try replacement.get()

        #expect(tierCalls.value == (teamRejection ? 1 : 0))
        #expect(result.usage.primary?.usedPercent == (teamRejection ? nil : 23))
        #expect(result.usage.accountEmail(for: .grok) == (teamRejection ? "a@example.com" : nil))
        #expect(result.usage.accountOrganization(for: .grok) == (teamRejection ? "team-a" : nil))
        #expect(result.usage.loginMethod(for: .grok) == (teamRejection ? "SuperGrok Heavy" : "Cookie Plan"))
        #expect(result.diagnostic == (teamRejection ? GrokStatusProbe.teamUsageUnavailableMessage : nil))
        #expect(result.sourceLabel == (teamRejection ? "grok-web" : "manual-cookie"))
    }

    @Test(arguments: ["proxy-failure", "known-usage", "unknown-usage", "enrichment-failure"])
    func `bearer fallback and unknown usage enrichment retain the original account`(route: String) async throws {
        let fixture = try GrokAccountFixture()
        defer { fixture.remove() }
        try fixture.write(account: "a")
        let calls = LockIsolated<[String]>([])
        let reset = Date(timeIntervalSince1970: 1_900_000_000)
        let strategy = GrokOAuthFetchStrategy(
            proxyBilling: { credentials in
                calls.setValue(calls.value + ["proxy"])
                Self.expectAccountA(credentials)
                try fixture.write(account: "b")
                if route == "proxy-failure" { throw GrokWebBillingError.invalidResponse }
                return GrokWebBillingSnapshot(usedPercent: nil, resetsAt: reset, subscriptionTier: "SuperGrok Heavy")
            },
            grpcBilling: { credentials in
                calls.setValue(calls.value + ["grpc"])
                Self.expectAccountA(credentials)
                if route == "enrichment-failure" { throw GrokWebBillingError.invalidResponse }
                return GrokWebBillingSnapshot(
                    usedPercent: route == "unknown-usage" ? nil : 42,
                    resetsAt: reset.addingTimeInterval(60))
            },
            webStrategy: .isolated,
            settingsTier: { credentials in
                calls.setValue(calls.value + ["tier"])
                Self.expectAccountA(credentials)
                return nil
            })
        let result = try await strategy.fetch(fixture.context())
        let knownUsage = route == "known-usage" || route == "proxy-failure"

        #expect(calls.value == ["proxy", "grpc", "tier"])
        #expect(result.usage.primary?.usedPercent == (knownUsage ? 42 : nil))
        if knownUsage {
            #expect(result.usage.primary?.resetsAt == (route == "proxy-failure" ? reset.addingTimeInterval(60) : reset))
        }
        #expect(result.usage.accountEmail(for: .grok) == "a@example.com")
        #expect(result.usage.accountOrganization(for: .grok) == "team-a")
        #expect(result.usage.loginMethod(for: .grok) == (route == "proxy-failure" ? "SuperGrok" : "SuperGrok Heavy"))
        #expect(result.sourceLabel == (knownUsage ? "grok-web" : "grok-cli-proxy"))
        #expect(result.diagnostic == (knownUsage ? nil : GrokStatusProbe.usageUnavailableMessage))
    }

    @Test(arguments: ["expired", "missing", "malformed", "empty"], [
        GrokOAuthFetchStrategy.Mode.proxyThenGrpc, .proxy, .grpc,
    ])
    func `oauth rejects unavailable credentials before billing or enrichment`(
        authState: String, mode: GrokOAuthFetchStrategy.Mode) async throws
    {
        let fixture = try GrokAccountFixture()
        defer { fixture.remove() }
        switch authState {
        case "expired": try fixture.write(account: "a", expired: true)
        case "malformed": try Data("not-json".utf8).write(to: fixture.home.appendingPathComponent("auth.json"))
        case "empty": try Data("{}".utf8).write(to: fixture.home.appendingPathComponent("auth.json"))
        default: break
        }
        let unexpectedBilling: GrokWebFetchStrategy.ProxyBillingFetch = { _ in
            Issue.record("Unavailable credentials must not reach billing")
            throw GrokWebBillingError.invalidResponse
        }
        let strategy = GrokOAuthFetchStrategy(
            mode: mode,
            proxyBilling: unexpectedBilling,
            grpcBilling: unexpectedBilling,
            webStrategy: .isolated,
            settingsTier: { _ in
                Issue.record("Unavailable credentials must not reach tier enrichment")
                return nil
            })
        let context = fixture.context()
        #expect(await strategy.isAvailable(context) == (authState != "missing"))
        await #expect {
            _ = try await strategy.fetch(context)
        } throws: { error in
            switch (authState, error) {
            case ("expired", GrokWebBillingError.missingCredentials),
                 ("missing", GrokCredentialsError.notFound),
                 ("malformed", GrokCredentialsError.decodeFailed),
                 ("empty", GrokCredentialsError.missingTokens): true
            default: false
            }
        }
    }

    @Test(arguments: ["missing", "expired", "personal"])
    func `team rejection does not invent a team identity`(authState: String) async throws {
        let fixture = try GrokAccountFixture()
        defer { fixture.remove() }
        if authState != "missing" {
            try fixture.write(
                account: "a", principal: authState == "personal" ? "Personal" : "Team", expired: authState == "expired")
        }
        await #expect {
            _ = try await GrokWebFetchStrategy.isolated.fetch(fixture.context(sourceMode: .web)) { _ in
                throw GrokWebBillingError.teamUsageUnsupported
            } settingsTier: { _ in
                Issue.record("Team fallback requires a valid team credential")
                return nil
            }
        } throws: { error in
            guard case GrokWebBillingError.teamUsageUnsupported = error else { return false }
            return true
        }
    }

    @Test(arguments: ["proxy", "grpc", "tier"], [false, true])
    func `cancellation stays cancellation across oauth billing and enrichment`(
        stage: String, urlCancellation: Bool) async throws
    {
        let fixture = try GrokAccountFixture()
        defer { fixture.remove() }
        try fixture.write(account: "a")
        let cancellation: any Error = urlCancellation ? URLError(.cancelled) : CancellationError()
        let calls = LockIsolated<[String]>([])
        let strategy = GrokOAuthFetchStrategy(
            proxyBilling: { _ in
                calls.setValue(calls.value + ["proxy"])
                if stage == "proxy" { throw cancellation }
                return GrokWebBillingSnapshot(usedPercent: stage == "grpc" ? nil : 37, resetsAt: nil)
            },
            grpcBilling: { _ in
                calls.setValue(calls.value + ["grpc"])
                throw cancellation
            },
            webStrategy: .isolated,
            settingsTier: { _ in
                calls.setValue(calls.value + ["tier"])
                throw cancellation
            })
        await #expect {
            _ = try await strategy.fetch(fixture.context())
        } throws: { error in
            urlCancellation ? (error as? URLError)?.code == .cancelled : error is CancellationError
        }
        #expect(calls.value == (stage == "proxy" ? ["proxy"] : ["proxy", stage]))
    }

    private static func expectAccountA(_ credentials: GrokCredentials?) {
        #expect(credentials?.accessToken == "fake-token-a")
        #expect(credentials?.refreshToken == "fake-refresh-a")
        #expect(credentials?.email == "a@example.com")
        #expect(credentials?.teamId == "team-a")
        #expect(credentials?.userId == "user-a")
        #expect(credentials?.scope == "https://auth.x.ai::fake-client")
        #expect(credentials?.authMode == "oidc")
        #expect(credentials?.isExpired == false)
    }
}

extension GrokWebFetchStrategy {
    static var isolated: Self {
        Self(localSummary: { _ in nil }, cliVersion: { _ in nil })
    }
}

private struct GrokAccountFixture: Sendable {
    let home: URL

    init() throws {
        self.home = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBar-GrokAccountContext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.home, withIntermediateDirectories: true)
    }

    func write(account: String, principal: String = "Personal", expired: Bool = false) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "https://auth.x.ai::fake-client": [
                "key": "fake-token-\(account)",
                "refresh_token": "fake-refresh-\(account)",
                "email": "\(account)@example.com",
                "team_id": "team-\(account)",
                "user_id": "user-\(account)",
                "auth_mode": "oidc",
                "principal_type": principal,
                "expires_at": expired ? "2000-01-01T00:00:00Z" : "2099-01-01T00:00:00Z",
            ],
        ])
        try data.write(to: self.home.appendingPathComponent("auth.json"), options: .atomic)
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.home)
    }

    func context(sourceMode: ProviderSourceMode = .oauth) -> ProviderFetchContext {
        #if os(macOS)
        let browserDetection = BrowserDetection(
            homeDirectory: self.home.path,
            cacheTTL: 0,
            now: Date.init,
            fileExists: { _ in false },
            directoryContents: { _ in nil },
            applicationURLs: { _ in [] },
            profileAccessIssue: { _ in nil })
        #else
        let browserDetection = BrowserDetection(cacheTTL: 0)
        #endif
        let environment = [
            "GROK_HOME": self.home.path,
            "GROK_CLI_PATH": self.home.appendingPathComponent("missing-grok").path,
            "PATH": self.home.path,
        ]
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: sourceMode,
            includeCredits: true,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: nil,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }
}

private actor GrokBillingGate {
    private var suspended = false
    private var observer: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.suspended = true
            self.observer?.resume()
            self.observer = nil
        }
    }

    func waitUntilSuspended() async {
        guard !self.suspended else { return }
        await withCheckedContinuation { self.observer = $0 }
    }

    func resume() {
        self.continuation?.resume()
        self.continuation = nil
    }
}
