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
            previousSourceLabel: "codex-cli",
            sourceLabel: "codex-cli",
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
            previousSourceLabel: "oauth",
            sourceLabel: "oauth",
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
            previousSourceLabel: "codex-cli",
            sourceLabel: "codex-cli",
            previous: previous,
            currentProviderData: current,
            now: now)

        #expect(decision == nil)
    }

    @Test
    func `decision skips provider data from credentials that do not match the CLI`() {
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

        #expect(RollingWindowAutoStartDecision.shouldStart(
            provider: .codex,
            previousSourceLabel: "codex-cli",
            sourceLabel: "openai-web",
            previous: previous,
            currentProviderData: current,
            now: now) == nil)
        #expect(RollingWindowAutoStartDecision.shouldStart(
            provider: .claude,
            previousSourceLabel: "claude",
            sourceLabel: "oauth",
            previous: previous,
            currentProviderData: current,
            now: now) == nil)
        #expect(RollingWindowAutoStartDecision.shouldStart(
            provider: .claude,
            previousSourceLabel: "web",
            sourceLabel: "claude",
            previous: previous,
            currentProviderData: current,
            now: now) == nil)
    }

    @Test
    func `claude decision selects five hour window instead of weekly primary`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let weeklyReset = now.addingTimeInterval(6 * 24 * 60 * 60)
        let expiredSessionReset = now.addingTimeInterval(-60)
        let previous = Self.snapshot(
            primary: RateWindow(
                usedPercent: 10,
                windowMinutes: 7 * 24 * 60,
                resetsAt: weeklyReset,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 20,
                windowMinutes: 5 * 60,
                resetsAt: expiredSessionReset,
                resetDescription: nil),
            updatedAt: now.addingTimeInterval(-120))
        let current = Self.snapshot(
            primary: RateWindow(
                usedPercent: 10,
                windowMinutes: 7 * 24 * 60,
                resetsAt: weeklyReset,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 0,
                windowMinutes: 5 * 60,
                resetsAt: nil,
                resetDescription: nil),
            updatedAt: now)

        let decision = RollingWindowAutoStartDecision.shouldStart(
            provider: .claude,
            previousSourceLabel: "claude",
            sourceLabel: "claude",
            previous: previous,
            currentProviderData: current,
            now: now)

        #expect(decision?.resetAt == expiredSessionReset)
    }

    @Test
    func `claude decision skips weekly only snapshots`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = Self.snapshot(
            primary: RateWindow(
                usedPercent: 10,
                windowMinutes: 7 * 24 * 60,
                resetsAt: now.addingTimeInterval(-60),
                resetDescription: nil),
            updatedAt: now.addingTimeInterval(-120))
        let current = Self.snapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 7 * 24 * 60,
                resetsAt: nil,
                resetDescription: nil),
            updatedAt: now)

        #expect(RollingWindowAutoStartDecision.shouldStart(
            provider: .claude,
            previousSourceLabel: "claude",
            sourceLabel: "claude",
            previous: previous,
            currentProviderData: current,
            now: now) == nil)
    }

    @Test
    func `only known prompt harness providers expose auto start support`() {
        #expect(RollingWindowAutoStartSupport.providers == [.codex, .claude])
        #expect(RollingWindowPingStarter.command(provider: .opencode, environment: [:]) == nil)
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
            previousSourceLabel: "codex-cli",
            sourceLabel: "codex-cli",
            previousSnapshot: previous,
            currentProviderData: current,
            now: now)
        store.scheduleRollingWindowAutoStartIfNeeded(
            provider: .codex,
            previousSourceLabel: "codex-cli",
            sourceLabel: "codex-cli",
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
        let managedID = UUID()
        let managedHome = "/tmp/codexbar-managed-codex-home"
        settings._test_activeManagedCodexRemoteHomePath = managedHome
        settings.codexActiveSource = .liveSystem
        defer { settings._test_activeManagedCodexRemoteHomePath = nil }

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
            previousSourceLabel: "oauth",
            sourceLabel: "oauth",
            previousSnapshot: previous,
            currentProviderData: current,
            codexActiveSourceOverride: .managedAccount(id: managedID),
            now: now)

        try await Self.waitForAutoStartToFinish(store: store, provider: .codex)
        let request = try #require(await runner.lastRequest)
        #expect(request.environment["CODEX_HOME"] == managedHome)
    }

    @Test
    func `scheduler deduplicates reset attempts per managed codex account`() async throws {
        let settings = try Self.makeSettingsStore(suite: "RollingWindowAutoStartTests-managed-codex-dedupe")
        settings.setRollingWindowAutoStartEnabled(provider: .codex, enabled: true)
        settings._test_activeManagedCodexRemoteHomePath = "/tmp/codexbar-managed-codex-home"
        defer { settings._test_activeManagedCodexRemoteHomePath = nil }

        let store = Self.makeUsageStore(settings: settings)
        let runner = RecordingRollingWindowPingRunner(delay: .milliseconds(25))
        store.rollingWindowAutoStartRuntime.testRunnerOverride = runner
        store._test_providerRefreshOverride = { _ in }

        let firstAccountID = UUID()
        let secondAccountID = UUID()
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
            previousSourceLabel: "oauth",
            sourceLabel: "oauth",
            previousSnapshot: previous,
            currentProviderData: current,
            codexActiveSourceOverride: .managedAccount(id: firstAccountID),
            now: now)
        store.scheduleRollingWindowAutoStartIfNeeded(
            provider: .codex,
            previousSourceLabel: "oauth",
            sourceLabel: "oauth",
            previousSnapshot: previous,
            currentProviderData: current,
            codexActiveSourceOverride: .managedAccount(id: secondAccountID),
            now: now)
        try await Self.waitForAutoStartToFinish(store: store, provider: .codex)

        #expect(await runner.count == 2)
        #expect(store.rollingWindowAutoStartRuntime.attemptedResetAt[
            .codexManagedAccount(firstAccountID),
        ] == expired)
        #expect(store.rollingWindowAutoStartRuntime.attemptedResetAt[
            .codexManagedAccount(secondAccountID),
        ] == expired)
    }

    @Test
    func `scheduler skips selected token account snapshots because prompt cli cannot be account bound`() async throws {
        let settings = try Self.makeSettingsStore(suite: "RollingWindowAutoStartTests-token-account-skip")
        settings.setRollingWindowAutoStartEnabled(provider: .claude, enabled: true)
        settings.addTokenAccount(provider: .claude, label: "Session", token: "sk-ant-session-token")
        let account = try #require(settings.selectedTokenAccount(for: .claude))
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
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            updatedAt: now)

        store.scheduleRollingWindowAutoStartIfNeeded(
            provider: .claude,
            previousSourceLabel: "claude",
            sourceLabel: "claude",
            previousSnapshot: previous,
            currentProviderData: current,
            tokenOverride: TokenAccountOverride(provider: .claude, account: account),
            now: now)

        try await Task.sleep(for: .milliseconds(25))
        #expect(await runner.isEmpty)
        #expect(store.rollingWindowAutoStartStatus[.claude] == nil)
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
            previousSourceLabel: "codex-cli",
            sourceLabel: "codex-cli",
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
            previousSourceLabel: "codex-cli",
            sourceLabel: "codex-cli",
            previousSnapshot: previous,
            currentProviderData: current,
            now: now)

        try await Self.waitForAutoStartToFinish(store: store, provider: .codex)
        #expect(await runner.count == 1)
        #expect(store.rollingWindowAutoStartRuntime.attemptedResetAt[.codexLiveSystem] == nil)
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
            if !store.rollingWindowAutoStartRuntime.inFlight.contains(where: { $0.provider == provider }) {
                return
            }
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
    private let delay: Duration?
    private(set) var count = 0
    private(set) var requests: [RollingWindowPingRequest] = []
    var isEmpty: Bool {
        self.count < 1
    }

    var lastRequest: RollingWindowPingRequest? {
        self.requests.last
    }

    init(error: Error? = nil, delay: Duration? = nil) {
        self.error = error
        self.delay = delay
    }

    func run(_ request: RollingWindowPingRequest) async throws {
        self.count += 1
        self.requests.append(request)
        if let delay {
            try await Task.sleep(for: delay)
        }
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
