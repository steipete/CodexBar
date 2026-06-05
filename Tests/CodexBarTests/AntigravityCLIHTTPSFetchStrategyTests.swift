import Foundation
import Testing
@testable import CodexBarCore

private final class AntigravityCLICounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        self.lock.lock()
        self.count += 1
        let value = self.count
        self.lock.unlock()
        return value
    }

    var value: Int {
        self.lock.lock()
        let value = self.count
        self.lock.unlock()
        return value
    }
}

private final class AntigravityCLIPortRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ports: [[Int]] = []

    func append(_ value: [Int]) {
        self.lock.lock()
        self.ports.append(value)
        self.lock.unlock()
    }

    func snapshot() -> [[Int]] {
        self.lock.lock()
        let value = self.ports
        self.lock.unlock()
        return value
    }
}

private final class AntigravityCLITimeoutRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var timeouts: [TimeInterval] = []

    func append(_ value: TimeInterval) {
        self.lock.lock()
        self.timeouts.append(value)
        self.lock.unlock()
    }

    func snapshot() -> [TimeInterval] {
        self.lock.lock()
        let value = self.timeouts
        self.lock.unlock()
        return value
    }
}

struct AntigravityCLIHTTPSFetchStrategyTests {
    @Test
    func `local strategy falls back to cli HTTPS in cli source mode`() {
        let strategy = AntigravityStatusFetchStrategy()
        let context = self.makeFetchContext(sourceMode: .cli)

        #expect(strategy.shouldFallback(on: AntigravityStatusProbeError.notRunning, context: context))
    }

    @Test
    func `local strategy falls back to cli HTTPS in auto source mode`() {
        let strategy = AntigravityStatusFetchStrategy()
        let context = self.makeFetchContext(sourceMode: .auto)

        #expect(strategy.shouldFallback(on: AntigravityStatusProbeError.notRunning, context: context))
    }

    @Test
    func `local strategy does not fallback for unrelated source modes`() {
        let strategy = AntigravityStatusFetchStrategy()

        #expect(!strategy.shouldFallback(
            on: AntigravityStatusProbeError.notRunning,
            context: self.makeFetchContext(sourceMode: .oauth)))
        #expect(!strategy.shouldFallback(
            on: AntigravityStatusProbeError.notRunning,
            context: self.makeFetchContext(sourceMode: .web)))
        #expect(!strategy.shouldFallback(
            on: AntigravityStatusProbeError.notRunning,
            context: self.makeFetchContext(sourceMode: .api)))
    }

    @Test
    func `strategy pipeline includes cli HTTPS fallback in cli and auto modes`() async {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .antigravity)

        let cliStrategies = await descriptor.fetchPlan.pipeline.resolveStrategies(
            self.makeFetchContext(sourceMode: .cli))
        #expect(cliStrategies.map(\.id) == ["antigravity.local", "antigravity.cli-https"])

        let autoStrategies = await descriptor.fetchPlan.pipeline.resolveStrategies(
            self.makeFetchContext(sourceMode: .auto))
        #expect(autoStrategies.map(\.id) == ["antigravity.local", "antigravity.cli-https", "antigravity.oauth"])
    }

    @Test
    func `strategy pipeline keeps source mode authoritative with selected token account`() async {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .antigravity)

        let accountID = UUID()
        let autoStrategies = await descriptor.fetchPlan.pipeline.resolveStrategies(
            self.makeFetchContext(sourceMode: .auto, selectedTokenAccountID: accountID))
        let cliStrategies = await descriptor.fetchPlan.pipeline.resolveStrategies(
            self.makeFetchContext(sourceMode: .cli, selectedTokenAccountID: accountID))
        let oauthStrategies = await descriptor.fetchPlan.pipeline.resolveStrategies(
            self.makeFetchContext(sourceMode: .oauth, selectedTokenAccountID: accountID))

        #expect(autoStrategies.map(\.id) == ["antigravity.local", "antigravity.cli-https", "antigravity.oauth"])
        #expect(cliStrategies.map(\.id) == ["antigravity.local", "antigravity.cli-https"])
        #expect(oauthStrategies.map(\.id) == ["antigravity.oauth"])
    }

    @Test
    func `cli HTTPS resets session only for short lived CLI runtime`() {
        #expect(AntigravityCLIHTTPSFetchStrategy.shouldResetSessionAfterFetch(self.makeFetchContext(runtime: .cli)))
        #expect(!AntigravityCLIHTTPSFetchStrategy.shouldResetSessionAfterFetch(self.makeFetchContext(runtime: .app)))
    }

    @Test
    func `cli HTTPS reports public source as cli`() {
        #expect(AntigravityCLIHTTPSFetchStrategy.sourceLabel == "cli")
    }

    @Test
    func `cli HTTPS falls back to command model configs when user status fails`() async throws {
        let endpoints = [
            AntigravityStatusProbe.AntigravityConnectionEndpoint(
                scheme: "https",
                port: 50080,
                csrfToken: "",
                source: .cliHTTPS),
        ]
        let attempts = AntigravityCLICounter()

        let snapshot = try await AntigravityStatusProbe.fetchSnapshot(
            context: AntigravityStatusProbe.RequestContext(
                endpoints: endpoints,
                timeout: 1,
                deadline: Date().addingTimeInterval(2)),
            send: { payload, _, _ in
                let attempt = attempts.increment()
                if attempt == 1 {
                    #expect(payload.path == "/exa.language_server_pb.LanguageServerService/GetUserStatus")
                    throw AntigravityStatusProbeError.apiError("user status unavailable")
                }
                #expect(payload.path == "/exa.language_server_pb.LanguageServerService/GetCommandModelConfigs")
                return Data("""
                {
                  "clientModelConfigs": [
                    {
                      "label": "Claude Sonnet",
                      "modelOrAlias": { "model": "claude-sonnet" },
                      "quotaInfo": { "remainingFraction": 0.5 }
                    }
                  ]
                }
                """.utf8)
            })

        #expect(snapshot.modelQuotas.first?.label == "Claude Sonnet")
        #expect(attempts.value == 2)
    }

    @Test
    func `cli HTTPS waits for user status after ports appear`() async throws {
        let fetchAttempts = AntigravityCLICounter()
        let drainAttempts = AntigravityCLICounter()
        let fetchedPorts = AntigravityCLIPortRecorder()
        let snapshot = try await AntigravityCLIHTTPSFetchStrategy.waitForSnapshot(
            pid: 123,
            deadline: Date().addingTimeInterval(5),
            dependencies: AntigravityCLIHTTPSFetchStrategy.SnapshotWaitDependencies(
                pollIntervalNanoseconds: 0,
                listeningPorts: { _, _ in [50080, 50081] },
                drainOutput: {
                    drainAttempts.increment()
                },
                fetchSnapshot: { ports in
                    fetchedPorts.append(ports)
                    if fetchAttempts.increment() == 1 {
                        throw AntigravityStatusProbeError.apiError("HTTP 500: GetCascadeModelConfigData() is nil")
                    }
                    return AntigravityStatusSnapshot(
                        modelQuotas: [
                            AntigravityModelQuota(
                                label: "Claude Opus 4.6 (Thinking)",
                                modelId: "claude-opus-4.6-thinking",
                                remainingFraction: 1,
                                resetTime: nil,
                                resetDescription: nil),
                        ],
                        accountEmail: "user@example.com",
                        accountPlan: "Pro",
                        source: .local)
                }))

        #expect(snapshot.accountEmail == "user@example.com")
        #expect(fetchAttempts.value == 2)
        #expect(fetchedPorts.snapshot() == [[50080, 50081], [50080, 50081]])
        #expect(drainAttempts.value == 2)
    }

    @Test
    func `cli HTTPS retries empty quota snapshots until usage is parseable`() async throws {
        let fetchAttempts = AntigravityCLICounter()

        let snapshot = try await AntigravityCLIHTTPSFetchStrategy.waitForSnapshot(
            pid: 123,
            deadline: Date().addingTimeInterval(5),
            dependencies: AntigravityCLIHTTPSFetchStrategy.SnapshotWaitDependencies(
                pollIntervalNanoseconds: 0,
                listeningPorts: { _, _ in [50080] },
                drainOutput: {},
                fetchSnapshot: { _ in
                    if fetchAttempts.increment() == 1 {
                        return AntigravityStatusSnapshot(
                            modelQuotas: [],
                            accountEmail: nil,
                            accountPlan: nil,
                            source: .local)
                    }
                    return AntigravityStatusSnapshot(
                        modelQuotas: [
                            AntigravityModelQuota(
                                label: "Claude Sonnet",
                                modelId: "claude-sonnet",
                                remainingFraction: 0.5,
                                resetTime: nil,
                                resetDescription: nil),
                        ],
                        accountEmail: "user@example.com",
                        accountPlan: "Pro",
                        source: .local)
                }))

        #expect(fetchAttempts.value == 2)
        #expect(snapshot.modelQuotas.first?.modelId == "claude-sonnet")
    }

    @Test
    func `cli HTTPS drains output before ports appear`() async throws {
        let portPolls = AntigravityCLICounter()
        let drainAttempts = AntigravityCLICounter()
        let snapshot = try await AntigravityCLIHTTPSFetchStrategy.waitForSnapshot(
            pid: 123,
            deadline: Date().addingTimeInterval(5),
            dependencies: AntigravityCLIHTTPSFetchStrategy.SnapshotWaitDependencies(
                pollIntervalNanoseconds: 0,
                listeningPorts: { _, _ in
                    portPolls.increment() == 1 ? [] : [50080]
                },
                drainOutput: {
                    drainAttempts.increment()
                },
                fetchSnapshot: { _ in
                    AntigravityStatusSnapshot(
                        modelQuotas: [
                            AntigravityModelQuota(
                                label: "Claude Sonnet",
                                modelId: "claude-sonnet",
                                remainingFraction: 1,
                                resetTime: nil,
                                resetDescription: nil),
                        ],
                        accountEmail: "user@example.com",
                        accountPlan: "Pro",
                        source: .local)
                }))

        #expect(snapshot.accountEmail == "user@example.com")
        #expect(portPolls.value == 2)
        #expect(drainAttempts.value == 2)
    }

    @Test
    func `cli HTTPS treats empty lsof exit as ports not ready`() async throws {
        let portPolls = AntigravityCLICounter()
        let snapshot = try await AntigravityCLIHTTPSFetchStrategy.waitForSnapshot(
            pid: 123,
            deadline: Date().addingTimeInterval(5),
            dependencies: AntigravityCLIHTTPSFetchStrategy.SnapshotWaitDependencies(
                pollIntervalNanoseconds: 0,
                listeningPorts: { _, _ in
                    if portPolls.increment() == 1 {
                        throw SubprocessRunnerError.nonZeroExit(code: 1, stderr: "")
                    }
                    return [50080]
                },
                drainOutput: {},
                fetchSnapshot: { _ in
                    AntigravityStatusSnapshot(
                        modelQuotas: [
                            AntigravityModelQuota(
                                label: "Claude Sonnet",
                                modelId: "claude-sonnet",
                                remainingFraction: 0.5,
                                resetTime: nil,
                                resetDescription: nil),
                        ],
                        accountEmail: "user@example.com",
                        accountPlan: "Pro",
                        source: .local)
                }))

        #expect(snapshot.accountEmail == "user@example.com")
        #expect(portPolls.value == 2)
    }

    @Test
    func `parsed requests recompute timeout from shared deadline between endpoints`() async throws {
        let timeoutRecorder = AntigravityCLITimeoutRecorder()
        let attempts = AntigravityCLICounter()
        let endpoints = [
            AntigravityStatusProbe.AntigravityConnectionEndpoint(
                scheme: "https",
                port: 50080,
                csrfToken: "",
                source: .cliHTTPS),
            AntigravityStatusProbe.AntigravityConnectionEndpoint(
                scheme: "https",
                port: 50081,
                csrfToken: "",
                source: .cliHTTPS),
        ]

        let result = try await AntigravityStatusProbe.makeParsedRequest(
            payload: AntigravityStatusProbe.RequestPayload(path: "/status", body: [:]),
            context: AntigravityStatusProbe.RequestContext(
                endpoints: endpoints,
                timeout: 10,
                deadline: Date().addingTimeInterval(2)),
            send: { _, _, timeout in
                timeoutRecorder.append(timeout)
                if attempts.increment() == 1 {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    throw AntigravityStatusProbeError.apiError("first endpoint failed")
                }
                return Data("ok".utf8)
            },
            parse: { data in
                guard let value = String(bytes: data, encoding: .utf8) else {
                    throw AntigravityStatusProbeError.apiError("invalid test data")
                }
                return value
            })

        let timeouts = timeoutRecorder.snapshot()
        #expect(result == "ok")
        #expect(timeouts.count == 2)
        #expect(timeouts.allSatisfy { $0 < 10 })
        #expect((timeouts.last ?? 10) < (timeouts.first ?? 0))
    }

    @Test
    func `parsed request reports timeout when shared deadline is already expired`() async {
        do {
            _ = try await AntigravityStatusProbe.makeParsedRequest(
                payload: AntigravityStatusProbe.RequestPayload(path: "/status", body: [:]),
                context: AntigravityStatusProbe.RequestContext(
                    endpoints: [
                        AntigravityStatusProbe.AntigravityConnectionEndpoint(
                            scheme: "https",
                            port: 50080,
                            csrfToken: "",
                            source: .cliHTTPS),
                    ],
                    timeout: 10,
                    deadline: Date().addingTimeInterval(-1)),
                send: { _, _, _ in
                    Issue.record("Expired deadline should not send a request")
                    return Data()
                },
                parse: { _ in "ok" })
            Issue.record("Expected timeout")
        } catch AntigravityStatusProbeError.timedOut {
        } catch {
            Issue.record("Expected timedOut, got \(error)")
        }
    }

    @Test
    func `cli HTTPS reports last readiness error when ports never become usable`() async {
        let fetchAttempts = AntigravityCLICounter()

        do {
            _ = try await AntigravityCLIHTTPSFetchStrategy.waitForSnapshot(
                pid: 123,
                deadline: Date().addingTimeInterval(2),
                dependencies: AntigravityCLIHTTPSFetchStrategy.SnapshotWaitDependencies(
                    pollIntervalNanoseconds: 10_000_000,
                    listeningPorts: { _, _ in [50080] },
                    drainOutput: {},
                    fetchSnapshot: { _ in
                        let attempt = fetchAttempts.increment()
                        throw AntigravityStatusProbeError.apiError("HTTP 500: warming attempt \(attempt)")
                    }))
            Issue.record("Expected readiness polling to throw")
        } catch let AntigravityStatusProbeError.apiError(message) {
            #expect(fetchAttempts.value > 1)
            #expect(message == "HTTP 500: warming attempt \(fetchAttempts.value)")
        } catch {
            Issue.record("Expected apiError, got \(error)")
        }
    }

    @Test
    func `cli HTTPS preserves non transient port detection errors`() async {
        do {
            _ = try await AntigravityCLIHTTPSFetchStrategy.waitForSnapshot(
                pid: 123,
                deadline: Date().addingTimeInterval(2),
                dependencies: AntigravityCLIHTTPSFetchStrategy.SnapshotWaitDependencies(
                    pollIntervalNanoseconds: 0,
                    listeningPorts: { _, _ in
                        throw AntigravityStatusProbeError.portDetectionFailed("lsof not available")
                    },
                    drainOutput: {},
                    fetchSnapshot: { _ in
                        Issue.record("Port detection failure should not fetch a snapshot")
                        return AntigravityStatusSnapshot(
                            modelQuotas: [],
                            accountEmail: nil,
                            accountPlan: nil,
                            source: .local)
                    }))
            Issue.record("Expected port detection failure")
        } catch let AntigravityStatusProbeError.portDetectionFailed(message) {
            #expect(message == "lsof not available")
        } catch {
            Issue.record("Expected portDetectionFailed, got \(error)")
        }
    }

    @Test
    func `cli HTTPS endpoint does not require CSRF token`() {
        let endpoint = AntigravityStatusProbe.AntigravityConnectionEndpoint(
            scheme: "https",
            port: 55624,
            csrfToken: "ignored-by-cli",
            source: .cliHTTPS)
        #expect(!endpoint.requiresCSRFToken)
    }

    @Test
    func `languageServer endpoint requires CSRF token`() {
        let endpoint = AntigravityStatusProbe.AntigravityConnectionEndpoint(
            scheme: "https",
            port: 64440,
            csrfToken: "",
            source: .languageServer)
        #expect(endpoint.requiresCSRFToken)
    }

    @Test
    func `extensionServer endpoint requires CSRF token`() {
        let endpoint = AntigravityStatusProbe.AntigravityConnectionEndpoint(
            scheme: "http",
            port: 64432,
            csrfToken: "",
            source: .extensionServer)
        #expect(endpoint.requiresCSRFToken)
    }

    private func makeFetchContext(
        runtime: ProviderRuntime = .app,
        sourceMode: ProviderSourceMode = .auto,
        selectedTokenAccountID: UUID? = nil) -> ProviderFetchContext
    {
        let env: [String: String] = [:]
        return ProviderFetchContext(
            runtime: runtime,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            selectedTokenAccountID: selectedTokenAccountID)
    }

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
}
