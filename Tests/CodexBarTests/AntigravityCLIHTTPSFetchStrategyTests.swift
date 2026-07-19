import Foundation
import Testing
@testable import CodexBarCore

private func antigravityBlockingSleep(_ interval: TimeInterval) {
    Thread.sleep(forTimeInterval: interval)
}

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

private final class AntigravityCLITestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(date: Date) {
        self.date = date
    }

    func now() -> Date {
        self.lock.lock()
        let value = self.date
        self.date = self.date.addingTimeInterval(1)
        self.lock.unlock()
        return value
    }
}

private final class AntigravityCLIOutputSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data]

    init(_ values: [Data]) {
        self.values = values
    }

    func next() -> Data {
        self.lock.lock()
        let value = self.values.isEmpty ? Data() : self.values.removeFirst()
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
        #expect(cliStrategies.map(\.id) == [
            "antigravity.app-local",
            "antigravity.cli-https",
            "antigravity.ide-local",
        ])

        let autoStrategies = await descriptor.fetchPlan.pipeline.resolveStrategies(
            self.makeFetchContext(sourceMode: .auto))
        #expect(autoStrategies.map(\.id) == [
            "antigravity.app-local",
            "antigravity.cli-https",
            "antigravity.ide-local",
        ])
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

        #expect(autoStrategies.map(\.id) == [
            "antigravity.app-local",
            "antigravity.cli-https",
            "antigravity.ide-local",
            "antigravity.oauth",
        ])
        #expect(cliStrategies.map(\.id) == [
            "antigravity.app-local",
            "antigravity.cli-https",
            "antigravity.ide-local",
        ])
        #expect(oauthStrategies.map(\.id) == ["antigravity.oauth"])
    }

    @Test
    func `auto strategy pipeline includes oauth when credentials are injected`() async {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .antigravity)

        let autoStrategies = await descriptor.fetchPlan.pipeline.resolveStrategies(
            self.makeFetchContext(
                sourceMode: .auto,
                env: self.accountEnv(email: "selected@example.com")))

        #expect(autoStrategies.map(\.id) == [
            "antigravity.app-local",
            "antigravity.cli-https",
            "antigravity.ide-local",
            "antigravity.oauth",
        ])
    }

    @Test
    func `auto strategy pipeline preserves oauth fallback for shared credentials file`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-shared-auto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AntigravityOAuthCredentialsStore(
            fileURL: AntigravityOAuthCredentialsStore.defaultURL(home: root))
        try store.save(AntigravityOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            expiryDate: Date().addingTimeInterval(3600),
            email: "legacy@example.com"))

        let descriptor = ProviderDescriptorRegistry.descriptor(for: .antigravity)
        let autoStrategies = await descriptor.fetchPlan.pipeline.resolveStrategies(
            self.makeFetchContext(sourceMode: .auto, env: ["HOME": root.path]))

        #expect(autoStrategies.map(\.id) == [
            "antigravity.app-local",
            "antigravity.cli-https",
            "antigravity.ide-local",
            "antigravity.oauth",
        ])
    }

    // MARK: - Selected-account guard

    @Test
    func `account guard ignores fetches without a selected account`() throws {
        let usage = self.makeUsage(accountEmail: "ambient@example.com")
        let context = self.makeFetchContext(
            sourceMode: .auto,
            env: self.accountEnv(email: "selected@example.com"))

        try AntigravitySelectedAccountGuard.validate(usage, context: context)
    }

    @Test
    func `account guard accepts matching ambient snapshot in auto mode`() throws {
        let usage = self.makeUsage(accountEmail: "Selected@Example.com")
        let context = self.makeFetchContext(
            sourceMode: .auto,
            selectedTokenAccountID: UUID(),
            env: self.accountEnv(email: "selected@example.com"))

        try AntigravitySelectedAccountGuard.validate(usage, context: context)
    }

    @Test
    func `account guard rejects mismatched ambient snapshot in auto mode`() {
        let usage = self.makeUsage(accountEmail: "ambient@example.com")
        let context = self.makeFetchContext(
            sourceMode: .auto,
            selectedTokenAccountID: UUID(),
            env: self.accountEnv(email: "selected@example.com"))

        #expect(throws: AntigravityStatusProbeError.accountMismatch(
            expected: "selected@example.com",
            found: "ambient@example.com"))
        {
            try AntigravitySelectedAccountGuard.validate(usage, context: context)
        }
    }

    @Test
    func `account guard rejects snapshot without an identity email`() {
        let usage = self.makeUsage(accountEmail: nil)
        let context = self.makeFetchContext(
            sourceMode: .auto,
            selectedTokenAccountID: UUID(),
            env: self.accountEnv(email: "selected@example.com"))

        #expect(throws: AntigravityStatusProbeError.accountMismatch(
            expected: "selected@example.com",
            found: nil))
        {
            try AntigravitySelectedAccountGuard.validate(usage, context: context)
        }
    }

    @Test
    func `account guard rejects when selected account email cannot be resolved`() {
        let usage = self.makeUsage(accountEmail: "ambient@example.com")
        let context = self.makeFetchContext(
            sourceMode: .auto,
            selectedTokenAccountID: UUID())

        #expect(throws: AntigravityStatusProbeError.accountMismatch(
            expected: nil,
            found: "ambient@example.com"))
        {
            try AntigravitySelectedAccountGuard.validate(usage, context: context)
        }
    }

    @Test
    func `account guard leaves explicit cli source mode authoritative`() throws {
        let usage = self.makeUsage(accountEmail: "ambient@example.com")
        let context = self.makeFetchContext(
            sourceMode: .cli,
            selectedTokenAccountID: UUID(),
            env: self.accountEnv(email: "selected@example.com"))

        try AntigravitySelectedAccountGuard.validate(usage, context: context)
    }

    @Test
    func `selected account email resolves from id_token when email field missing`() {
        let idToken = Self.makeIDToken(email: "jwt@example.com")
        let context = self.makeFetchContext(
            sourceMode: .auto,
            selectedTokenAccountID: UUID(),
            env: self.accountEnv(email: nil, idToken: idToken))

        #expect(AntigravitySelectedAccountGuard.selectedAccountEmail(context: context) == "jwt@example.com")
    }

    @Test
    func `selected account email prefers id_token over stored email field`() {
        let idToken = Self.makeIDToken(email: "jwt@example.com")
        let context = self.makeFetchContext(
            sourceMode: .auto,
            selectedTokenAccountID: UUID(),
            env: self.accountEnv(email: "stored@example.com", idToken: idToken))

        #expect(AntigravitySelectedAccountGuard.selectedAccountEmail(context: context) == "jwt@example.com")
    }

    @Test
    func `cli HTTPS resets session only for one-shot CLI runtime`() {
        // One-shot CLI invocation: reset after fetch.
        #expect(AntigravityCLIHTTPSFetchStrategy.shouldResetSessionAfterFetch(self.makeFetchContext(runtime: .cli)))
        // App runtime keeps the warm session.
        #expect(!AntigravityCLIHTTPSFetchStrategy.shouldResetSessionAfterFetch(self.makeFetchContext(runtime: .app)))
        // Long-lived CLI host (codexbar serve) keeps the warm session even at .cli runtime.
        #expect(!AntigravityCLIHTTPSFetchStrategy.shouldResetSessionAfterFetch(
            self.makeFetchContext(runtime: .cli, persistsCLISessions: true)))
    }

    @Test
    func `cli HTTPS reports public source as cli`() {
        #expect(AntigravityCLIHTTPSFetchStrategy.sourceLabel == "cli")
    }

    @Test
    func `cli local strategy availability requires binary`() async throws {
        let binaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-antigravity-\(UUID().uuidString)")
        try Data("#!/bin/sh\n".utf8).write(to: binaryURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: binaryURL.path)
        defer { try? FileManager.default.removeItem(at: binaryURL) }

        let strategy = AntigravityCLIHTTPSFetchStrategy()
        let context = self.makeFetchContext(env: ["ANTIGRAVITY_CLI_PATH": binaryURL.path])
        let isAvailable = await strategy.isAvailable(context)

        #expect(isAvailable)
    }

    @Test
    func `cli local endpoints remain HTTPS only on macOS`() {
        #expect(
            AntigravityStatusProbe.cliEndpoints(ports: [55624]) == [
                AntigravityStatusProbe.AntigravityConnectionEndpoint(
                    scheme: "https",
                    port: 55624,
                    csrfToken: "",
                    source: .cliHTTPS),
            ])
    }

    @Test
    func `cli HTTPS falls back to command model configs when quota summary and user status fail`() async throws {
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
                    #expect(payload.path == "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary")
                    throw AntigravityStatusProbeError.apiError("quota summary unavailable")
                }
                if attempt == 2 {
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
        #expect(attempts.value == 3)
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
                    return Data()
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
        #expect(drainAttempts.value == 4)
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
                drainOutput: { Data() },
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
                    return Data()
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
        #expect(drainAttempts.value == 3)
    }

    @Test
    func `cli HTTPS stops before probing when signed out prompt spans output chunks`() async {
        let output = AntigravityCLIOutputSequence([
            Data("Welcome. You are currently ".utf8),
            Data("Welcome. You are currently not signed in.\nSelect login method:".utf8),
        ])
        let portPolls = AntigravityCLICounter()

        do {
            _ = try await AntigravityCLIHTTPSFetchStrategy.waitForSnapshot(
                pid: 123,
                deadline: Date().addingTimeInterval(2),
                dependencies: AntigravityCLIHTTPSFetchStrategy.SnapshotWaitDependencies(
                    pollIntervalNanoseconds: 0,
                    listeningPorts: { _, _ in
                        portPolls.increment()
                        return []
                    },
                    drainOutput: {
                        output.next()
                    },
                    fetchSnapshot: { _ in
                        Issue.record("Signed-out helper should not fetch a snapshot")
                        return AntigravityStatusSnapshot(
                            modelQuotas: [],
                            accountEmail: nil,
                            accountPlan: nil,
                            source: .local)
                    }))
            Issue.record("Expected authentication failure")
        } catch AntigravityStatusProbeError.authenticationRequired {
            #expect(portPolls.value == 1)
        } catch {
            Issue.record("Expected authenticationRequired, got \(error)")
        }
    }

    @Test
    func `cli HTTPS allows transient automatic sign in banner`() async throws {
        let output = AntigravityCLIOutputSequence([
            Data("Welcome. You are currently not signed in.\nSigning in...".utf8),
            Data("user@example.com\nGemini 3.1 Pro (High)".utf8),
        ])

        let snapshot = try await AntigravityCLIHTTPSFetchStrategy.waitForSnapshot(
            pid: 123,
            deadline: Date().addingTimeInterval(2),
            dependencies: AntigravityCLIHTTPSFetchStrategy.SnapshotWaitDependencies(
                pollIntervalNanoseconds: 0,
                listeningPorts: { _, _ in [50080] },
                drainOutput: {
                    output.next()
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
    }

    @Test
    func `cli HTTPS rechecks signed out prompt after snapshot readiness`() async {
        let output = AntigravityCLIOutputSequence([
            Data(),
            Data("You are currently not signed in.\nSelect login method:".utf8),
        ])

        do {
            _ = try await AntigravityCLIHTTPSFetchStrategy.waitForSnapshot(
                pid: 123,
                deadline: Date().addingTimeInterval(2),
                dependencies: AntigravityCLIHTTPSFetchStrategy.SnapshotWaitDependencies(
                    pollIntervalNanoseconds: 0,
                    listeningPorts: { _, _ in [50080] },
                    drainOutput: {
                        output.next()
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
            Issue.record("Expected authentication failure")
        } catch AntigravityStatusProbeError.authenticationRequired {
            // Expected: the late prompt wins over the apparently ready API.
        } catch {
            Issue.record("Expected authenticationRequired, got \(error)")
        }
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
                drainOutput: { Data() },
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
                deadline: Date().addingTimeInterval(10)),
            send: { _, _, timeout in
                timeoutRecorder.append(timeout)
                if attempts.increment() == 1 {
                    antigravityBlockingSleep(0.1)
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
        #expect(timeouts.allSatisfy { $0 <= 10 })
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
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let clock = AntigravityCLITestClock(date: start)

        do {
            _ = try await AntigravityCLIHTTPSFetchStrategy.waitForSnapshot(
                pid: 123,
                deadline: start.addingTimeInterval(5),
                dependencies: AntigravityCLIHTTPSFetchStrategy.SnapshotWaitDependencies(
                    pollIntervalNanoseconds: 0,
                    listeningPorts: { _, _ in [50080] },
                    drainOutput: { Data() },
                    fetchSnapshot: { _ in
                        let attempt = fetchAttempts.increment()
                        throw AntigravityStatusProbeError.apiError("HTTP 500: warming attempt \(attempt)")
                    },
                    now: { clock.now() }))
            Issue.record("Expected readiness polling to throw")
        } catch let AntigravityStatusProbeError.apiError(message) {
            #expect(fetchAttempts.value == 2)
            #expect(message == "HTTP 500: warming attempt 2")
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
                    drainOutput: { Data() },
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
        selectedTokenAccountID: UUID? = nil,
        persistsCLISessions: Bool = false,
        env: [String: String] = [:]) -> ProviderFetchContext
    {
        var effectiveEnv = env
        effectiveEnv["HOME"] = effectiveEnv["HOME"] ??
            FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-antigravity-empty-home-\(UUID().uuidString)", isDirectory: true)
            .path
        return ProviderFetchContext(
            runtime: runtime,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: effectiveEnv,
            settings: nil,
            fetcher: UsageFetcher(environment: effectiveEnv),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            selectedTokenAccountID: selectedTokenAccountID,
            persistsCLISessions: persistsCLISessions)
    }

    private func makeUsage(accountEmail: String?) -> UsageSnapshot {
        UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .antigravity,
                accountEmail: accountEmail,
                accountOrganization: nil,
                loginMethod: nil))
    }

    private func accountEnv(email: String?, idToken: String? = nil) -> [String: String] {
        let credentials = AntigravityOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            expiryDate: Date().addingTimeInterval(3600),
            idToken: idToken,
            email: email)
        guard let value = try? AntigravityOAuthCredentialsStore.tokenAccountValue(for: credentials) else {
            return [:]
        }
        return [AntigravityOAuthCredentialsStore.environmentCredentialsKey: value]
    }

    private static func makeIDToken(email: String) -> String {
        let payload = Data("{\"email\":\"\(email)\"}".utf8)
        let encodedPayload = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encodedPayload).signature"
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
