import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct RollingWindowAutoStartTests {
    @Test
    func `setting is disabled by default and persists when enabled`() throws {
        let suite = "RollingWindowAutoStartTests-setting"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(settings.rollingWindowAutoStartEnabled(provider: .codex) == false)

        settings.setRollingWindowAutoStartEnabled(provider: .codex, enabled: true)

        #expect(settings.rollingWindowAutoStartEnabled(provider: .codex) == true)
        #expect(settings.providerConfig(for: .codex)?.rollingWindowAutoStartEnabled == true)

        settings.setRollingWindowAutoStartEnabled(provider: .codex, enabled: false)

        #expect(settings.rollingWindowAutoStartEnabled(provider: .codex) == false)
        #expect(settings.providerConfig(for: .codex)?.rollingWindowAutoStartEnabled == nil)
    }

    @Test
    func `decision starts when previous rolling window expired and provider data has no active replacement`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = now.addingTimeInterval(-60)
        let previous = Self.snapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: expired, resetDescription: nil),
            updatedAt: now.addingTimeInterval(-120))
        let current = Self.snapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            updatedAt: now)

        let decision = RollingWindowAutoStartDecision.shouldStart(
            provider: .codex,
            previous: previous,
            currentProviderData: current,
            now: now)

        #expect(decision?.resetAt == expired)
    }

    @Test
    func `decision skips when provider data already has active rolling window`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = Self.snapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(-60),
                resetDescription: nil),
            updatedAt: now.addingTimeInterval(-120))
        let current = Self.snapshot(
            primary: RateWindow(
                usedPercent: 1,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(5 * 60 * 60),
                resetDescription: nil),
            updatedAt: now)

        let decision = RollingWindowAutoStartDecision.shouldStart(
            provider: .codex,
            previous: previous,
            currentProviderData: current,
            now: now)

        #expect(decision == nil)
    }

    @Test
    func `decision skips when provider data has no rolling window`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = Self.snapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(-60),
                resetDescription: nil),
            updatedAt: now.addingTimeInterval(-120))
        let current = Self.snapshot(primary: nil, updatedAt: now)

        let decision = RollingWindowAutoStartDecision.shouldStart(
            provider: .codex,
            previous: previous,
            currentProviderData: current,
            now: now)

        #expect(decision == nil)
    }

    @Test
    func `only known prompt harness providers expose auto start support`() {
        #expect(RollingWindowAutoStartSupport.providers == [.codex, .claude, .opencode])
        #expect(RollingWindowPingStarter.command(provider: .opencodego, environment: [:]) == nil)
        #expect(RollingWindowPingStarter.command(provider: .zai, environment: [:]) == nil)
    }

    @Test
    func `codex command uses ephemeral low reasoning mini model by default`() throws {
        let command = try #require(RollingWindowPingStarter.command(provider: .codex, environment: [:]))

        #expect(command.arguments.contains("exec"))
        #expect(command.arguments.contains("--ephemeral"))
        #expect(command.arguments.contains("--skip-git-repo-check"))
        #expect(command.arguments.contains("gpt-5.4-mini"))
        #expect(command.arguments.contains("model_reasoning_effort=low"))
        #expect(command.arguments.last == "Say hi, then stop.")
    }

    @Test
    func `claude command disables session persistence`() throws {
        let command = try #require(RollingWindowPingStarter.command(provider: .claude, environment: [:]))

        #expect(command.arguments.contains("-p"))
        #expect(command.arguments.contains("--no-session-persistence"))
        #expect(command.arguments.contains("haiku"))
        #expect(command.arguments.last == "Say hi, then stop.")
    }

    @Test
    func `scheduler starts once per reset and refreshes after ping`() async throws {
        let settings = try Self.makeSettingsStore(suite: "RollingWindowAutoStartTests-scheduler-once")
        settings.setRollingWindowAutoStartEnabled(provider: .codex, enabled: true)
        let store = Self.makeUsageStore(settings: settings)
        let runner = RecordingRollingWindowPingRunner()
        store.rollingWindowAutoStartRuntime.testRunnerOverride = runner
        var refreshCount = 0
        store._test_providerRefreshOverride = { _ in
            refreshCount += 1
        }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = now.addingTimeInterval(-60)
        let previous = Self.snapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: expired, resetDescription: nil),
            updatedAt: now.addingTimeInterval(-120))
        let current = Self.snapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            updatedAt: now)

        store.scheduleRollingWindowAutoStartIfNeeded(
            provider: .codex,
            previousSnapshot: previous,
            currentProviderData: current,
            now: now)
        store.scheduleRollingWindowAutoStartIfNeeded(
            provider: .codex,
            previousSnapshot: previous,
            currentProviderData: current,
            now: now)

        try await Self.waitForAutoStartToFinish(store: store, provider: .codex)
        #expect(await runner.count == 1)
        #expect(refreshCount == 1)
        #expect(store.rollingWindowAutoStartStatus[.codex] == "Ping prompt sent.")
    }

    @Test
    func `scheduler routes codex ping through selected managed account environment`() async throws {
        let settings = try Self.makeSettingsStore(suite: "RollingWindowAutoStartTests-managed-codex-route")
        settings.setRollingWindowAutoStartEnabled(provider: .codex, enabled: true)
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/codexbar-managed-codex-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        settings._test_activeManagedCodexAccount = managedAccount
        settings.codexActiveSource = .managedAccount(id: managedAccount.id)
        defer { settings._test_activeManagedCodexAccount = nil }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: ["CODEX_HOME": "/tmp/codexbar-ambient-codex-home"])
        let runner = RecordingRollingWindowPingRunner()
        store.rollingWindowAutoStartRuntime.testRunnerOverride = runner
        store._test_providerRefreshOverride = { _ in }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = Self.snapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(-60),
                resetDescription: nil),
            updatedAt: now.addingTimeInterval(-120))
        let current = Self.snapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            updatedAt: now)

        store.scheduleRollingWindowAutoStartIfNeeded(
            provider: .codex,
            previousSnapshot: previous,
            currentProviderData: current,
            now: now)

        try await Self.waitForAutoStartToFinish(store: store, provider: .codex)
        let request = try #require(await runner.lastRequest)
        #expect(request.environment["CODEX_HOME"] == managedAccount.managedHomePath)
    }

    @Test
    func `scheduler skips when current snapshot has active window`() async throws {
        let settings = try Self.makeSettingsStore(suite: "RollingWindowAutoStartTests-scheduler-active")
        settings.setRollingWindowAutoStartEnabled(provider: .codex, enabled: true)
        let store = Self.makeUsageStore(settings: settings)
        let runner = RecordingRollingWindowPingRunner()
        store.rollingWindowAutoStartRuntime.testRunnerOverride = runner

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = Self.snapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(-60),
                resetDescription: nil),
            updatedAt: now.addingTimeInterval(-120))
        let current = Self.snapshot(
            primary: RateWindow(
                usedPercent: 1,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(300),
                resetDescription: nil),
            updatedAt: now)

        store.scheduleRollingWindowAutoStartIfNeeded(
            provider: .codex,
            previousSnapshot: previous,
            currentProviderData: current,
            now: now)

        try await Task.sleep(for: .milliseconds(25))
        #expect(await runner.isEmpty)
        #expect(store.rollingWindowAutoStartStatus[.codex] == nil)
    }

    @Test
    func `scheduler clears attempted reset after ping failure`() async throws {
        let settings = try Self.makeSettingsStore(suite: "RollingWindowAutoStartTests-scheduler-failure")
        settings.setRollingWindowAutoStartEnabled(provider: .codex, enabled: true)
        let store = Self.makeUsageStore(settings: settings)
        let runner = RecordingRollingWindowPingRunner(error: TestPingError())
        store.rollingWindowAutoStartRuntime.testRunnerOverride = runner

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = now.addingTimeInterval(-60)
        let previous = Self.snapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: expired, resetDescription: nil),
            updatedAt: now.addingTimeInterval(-120))
        let current = Self.snapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            updatedAt: now)

        store.scheduleRollingWindowAutoStartIfNeeded(
            provider: .codex,
            previousSnapshot: previous,
            currentProviderData: current,
            now: now)

        try await Self.waitForAutoStartToFinish(store: store, provider: .codex)
        #expect(await runner.count == 1)
        #expect(store.rollingWindowAutoStartRuntime.attemptedResetAt[.codex] == nil)
        #expect(store.rollingWindowAutoStartStatus[.codex] == "test ping failed")
    }

    private static func makeSettingsStore(suite: String) throws -> SettingsStore {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private static func makeUsageStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }

    private static func waitForAutoStartToFinish(store: UsageStore, provider: UsageProvider) async throws {
        for _ in 0..<50 {
            if !store.rollingWindowAutoStartRuntime.inFlight.contains(provider) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for rolling window auto-start to finish")
    }

    private static func snapshot(
        primary: RateWindow?,
        secondary: RateWindow? = nil,
        tertiary: RateWindow? = nil,
        updatedAt: Date) -> UsageSnapshot
    {
        UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            updatedAt: updatedAt)
    }
}

private actor RecordingRollingWindowPingRunner: RollingWindowPingRunning {
    private let error: Error?
    private(set) var count = 0
    private(set) var requests: [RollingWindowPingRequest] = []
    var isEmpty: Bool {
        self.count < 1
    }

    var lastRequest: RollingWindowPingRequest? {
        self.requests.last
    }

    init(error: Error? = nil) {
        self.error = error
    }

    func run(_ request: RollingWindowPingRequest) async throws {
        self.count += 1
        self.requests.append(request)
        if let error {
            throw error
        }
    }
}

private struct TestPingError: LocalizedError {
    var errorDescription: String? {
        "test ping failed"
    }
}
