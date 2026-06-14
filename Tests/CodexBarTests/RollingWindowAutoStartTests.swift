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
    func `decision starts for codex OpenAI web snapshots routed through codex cli`() {
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
            previousSourceLabel: "openai-web",
            sourceLabel: "openai-web",
            previous: previous,
            currentProviderData: current,
            now: now)

        #expect(decision?.resetAt == expired)
    }

    @Test
    func `decision starts for inactive codex OpenAI web snapshot without previous reset`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let current = Self.snapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            updatedAt: now)

        let decision = RollingWindowAutoStartDecision.shouldStart(
            provider: .codex,
            previousSourceLabel: nil,
            sourceLabel: "openai-web",
            previous: nil,
            currentProviderData: current,
            now: now)

        #expect(decision?.resetAt == nil)
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
    func `decision skips when secondary quota window is exhausted`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = now.addingTimeInterval(-60)
        let weeklyExhausted = RateWindow(
            usedPercent: 100,
            windowMinutes: 7 * 24 * 60,
            resetsAt: now.addingTimeInterval(2 * 24 * 60 * 60),
            resetDescription: nil)
        let previous = Self.snapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: expired, resetDescription: nil),
            secondary: weeklyExhausted,
            updatedAt: now.addingTimeInterval(-120))
        let current = Self.snapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: weeklyExhausted,
            updatedAt: now)

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
    func `decision accepts claude web or oauth candidates for scheduler route validation`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = now.addingTimeInterval(-60)
        let previous = Self.snapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: expired,
                resetDescription: nil),
            updatedAt: now.addingTimeInterval(-120))
        let current = Self.snapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            updatedAt: now)

        #expect(RollingWindowAutoStartDecision.shouldStart(
            provider: .claude,
            previousSourceLabel: "claude",
            sourceLabel: "oauth",
            previous: previous,
            currentProviderData: current,
            now: now)?.resetAt == expired)
        #expect(RollingWindowAutoStartDecision.shouldStart(
            provider: .claude,
            previousSourceLabel: "web",
            sourceLabel: "claude",
            previous: previous,
            currentProviderData: current,
            now: now)?.resetAt == expired)
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
    func `claude decision skips when weekly quota window is exhausted`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredSessionReset = now.addingTimeInterval(-60)
        let exhaustedWeekly = RateWindow(
            usedPercent: 100,
            windowMinutes: 7 * 24 * 60,
            resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60),
            resetDescription: nil)
        let previous = Self.snapshot(
            primary: exhaustedWeekly,
            secondary: RateWindow(
                usedPercent: 20,
                windowMinutes: 5 * 60,
                resetsAt: expiredSessionReset,
                resetDescription: nil),
            provider: .claude,
            updatedAt: now.addingTimeInterval(-120))
        let current = Self.snapshot(
            primary: exhaustedWeekly,
            secondary: RateWindow(
                usedPercent: 0,
                windowMinutes: 5 * 60,
                resetsAt: nil,
                resetDescription: nil),
            provider: .claude,
            updatedAt: now)

        let decision = RollingWindowAutoStartDecision.shouldStart(
            provider: .claude,
            previousSourceLabel: "web",
            sourceLabel: "web",
            previous: previous,
            currentProviderData: current,
            now: now)

        #expect(decision == nil)
    }

    @Test
    func `only known prompt harness providers expose auto start support`() {
        #expect(RollingWindowAutoStartSupport.providers == [.codex, .claude])
        #expect(RollingWindowPingStarter.command(provider: .opencode, environment: [:]) == nil)
        #expect(RollingWindowPingStarter.command(provider: .opencodego, environment: [:]) == nil)
        #expect(RollingWindowPingStarter.command(provider: .zai, environment: [:]) == nil)
    }

    @Test
    func `log metadata labels routes and old reset timestamp clearly`() throws {
        let accountID = try #require(UUID(uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF"))
        let resetAt = Date(timeIntervalSince1970: 1_800_000_000)

        let metadata = UsageStore.rollingWindowAutoStartLogMetadata(
            provider: .codex,
            route: .codexManagedAccount(accountID),
            previousSourceLabel: nil,
            sourceLabel: "oauth",
            decision: RollingWindowAutoStartDecision(
                resetAt: resetAt,
                resetSource: .previousExpiredReset))

        #expect(metadata["provider"] == "codex")
        #expect(metadata["route"] == "codex-managed-account:123456...ABCDEF")
        #expect(metadata["route"]?.contains(accountID.uuidString) == false)
        #expect(metadata["previousSource"] == "none")
        #expect(metadata["source"] == "oauth")
        #expect(metadata["resetAt"] == "2027-01-15T08:00:00.000Z")
        #expect(metadata["resetSource"] == "previous-expired-reset")
        #expect(metadata["trigger"] == "expired-previous-reset")
        #expect(metadata["previousResetAt"] == nil)
        #expect(metadata["expiredResetAt"] == nil)
    }

    @Test
    func `log helpers format all route cases and nil timestamps`() throws {
        let accountID = try #require(UUID(uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF"))

        #expect(UsageStore.rollingWindowAutoStartRouteLabel(.provider(.claude)) == "provider:claude")
        #expect(UsageStore.rollingWindowAutoStartRouteLabel(.codexLiveSystem) == "codex-live-system")
        #expect(UsageStore.rollingWindowAutoStartRouteLabel(.codexManagedAccount(accountID)) ==
            "codex-managed-account:123456...ABCDEF")
        #expect(UsageStore.rollingWindowAutoStartTimestamp(nil) == "none")
    }

    @Test
    func `codex command persists a low reasoning mini model session by default`() throws {
        let command = try #require(RollingWindowPingStarter.command(provider: .codex, environment: [:]))

        #expect(command.arguments.contains("exec"))
        #expect(!command.arguments.contains("--ephemeral"))
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
    func `scheduler starts codex ping for OpenAI web snapshot with expired prior reset`() async throws {
        let settings = try Self.makeSettingsStore(suite: "RollingWindowAutoStartTests-scheduler-openai-web")
        settings.setRollingWindowAutoStartEnabled(provider: .codex, enabled: true)
        settings._test_liveSystemCodexAccount = Self.liveSystemCodexAccount(email: "codex@example.com")
        defer { settings._test_liveSystemCodexAccount = nil }
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
            accountEmail: "codex@example.com",
            updatedAt: now)

        store.scheduleRollingWindowAutoStartIfNeeded(
            provider: .codex,
            previousSourceLabel: "openai-web",
            sourceLabel: "openai-web",
            previousSnapshot: previous,
            currentProviderData: current,
            now: now)

        try await Self.waitForAutoStartToFinish(store: store, provider: .codex)
        #expect(await runner.count == 1)
        #expect(refreshCount == 1)
        #expect(store.rollingWindowAutoStartRuntime.attemptedResetAt[.codexLiveSystem] == expired)
    }

    @Test
    func `scheduler starts codex ping for inactive OpenAI web snapshot without prior reset`() async throws {
        let settings = try Self.makeSettingsStore(suite: "RollingWindowAutoStartTests-scheduler-openai-web-no-reset")
        settings.setRollingWindowAutoStartEnabled(provider: .codex, enabled: true)
        settings._test_liveSystemCodexAccount = Self.liveSystemCodexAccount(email: "codex@example.com")
        defer { settings._test_liveSystemCodexAccount = nil }
        let store = Self.makeUsageStore(settings: settings)
        let runner = RecordingRollingWindowPingRunner()
        store.rollingWindowAutoStartRuntime.testRunnerOverride = runner
        var refreshCount = 0
        store._test_providerRefreshOverride = { _ in
            refreshCount += 1
        }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let current = Self.snapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            accountEmail: "codex@example.com",
            updatedAt: now)

        store.scheduleRollingWindowAutoStartIfNeeded(
            provider: .codex,
            previousSourceLabel: nil,
            sourceLabel: "openai-web",
            previousSnapshot: nil,
            currentProviderData: current,
            now: now)

        try await Self.waitForAutoStartToFinish(store: store, provider: .codex)
        #expect(await runner.count == 1)
        #expect(refreshCount == 1)
        #expect(store.rollingWindowAutoStartRuntime.attemptedInactiveWithoutReset.contains(.codexLiveSystem))
        #expect(store.rollingWindowAutoStartRuntime.attemptedResetAt[.codexLiveSystem] == nil)
    }

    @Test
    func `scheduler skips codex OpenAI web snapshot when live cli account differs`() async throws {
        let settings = try Self.makeSettingsStore(suite: "RollingWindowAutoStartTests-scheduler-openai-web-mismatch")
        settings.setRollingWindowAutoStartEnabled(provider: .codex, enabled: true)
        settings._test_liveSystemCodexAccount = Self.liveSystemCodexAccount(email: "cli@example.com")
        defer { settings._test_liveSystemCodexAccount = nil }
        let store = Self.makeUsageStore(settings: settings)
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
            accountEmail: "web@example.com",
            updatedAt: now.addingTimeInterval(-120))
        let current = Self.snapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            accountEmail: "web@example.com",
            updatedAt: now)

        store.scheduleRollingWindowAutoStartIfNeeded(
            provider: .codex,
            previousSourceLabel: "openai-web",
            sourceLabel: "openai-web",
            previousSnapshot: previous,
            currentProviderData: current,
            now: now)

        #expect(await runner.isEmpty)
        #expect(store.rollingWindowAutoStartStatus[.codex] ==
            "Skipped: usage account does not match prompt CLI account.")
    }

    @Test
    func `scheduler skips claude web snapshot because prompt cli account cannot be verified`() async throws {
        let settings = try Self.makeSettingsStore(suite: "RollingWindowAutoStartTests-scheduler-claude-web-mismatch")
        settings.setRollingWindowAutoStartEnabled(provider: .claude, enabled: true)
        let store = Self.makeUsageStore(settings: settings)
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
            accountEmail: "web@example.com",
            provider: .claude,
            updatedAt: now.addingTimeInterval(-120))
        let current = Self.snapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            accountEmail: "web@example.com",
            provider: .claude,
            updatedAt: now)

        store.scheduleRollingWindowAutoStartIfNeeded(
            provider: .claude,
            previousSourceLabel: "web",
            sourceLabel: "web",
            previousSnapshot: previous,
            currentProviderData: current,
            now: now)

        #expect(await runner.isEmpty)
        #expect(store.rollingWindowAutoStartStatus[.claude] ==
            "Skipped: usage account cannot be verified against prompt CLI account.")
    }

    @Test
    func `scheduler forces refresh after ping when triggering refresh is still registered`() async throws {
        let settings = try Self.makeSettingsStore(suite: "RollingWindowAutoStartTests-scheduler-uncoalesced")
        settings.setRollingWindowAutoStartEnabled(provider: .codex, enabled: true)
        let store = Self.makeUsageStore(settings: settings)
        let runner = RecordingRollingWindowPingRunner()
        store.rollingWindowAutoStartRuntime.testRunnerOverride = runner
        var refreshCount = 0
        store._test_providerRefreshOverride = { _ in
            refreshCount += 1
        }

        let lingeringGeneration: UInt64 = 10
        let lingeringState = ProviderRefreshTaskState(generation: lingeringGeneration)
        lingeringState.install(task: Task {})
        lingeringState.markCompleted(retryRequired: false)
        store.providerRefreshTasks[.codex] = [lingeringState]
        store.latestProviderRefreshGenerations[.codex] = lingeringGeneration
        store.providerRefreshTaskGeneration = lingeringGeneration

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
            previousSourceLabel: "codex-cli",
            sourceLabel: "codex-cli",
            previousSnapshot: previous,
            currentProviderData: current,
            now: now)

        try await Self.waitForAutoStartToFinish(store: store, provider: .codex)
        #expect(await runner.count == 1)
        #expect(refreshCount == 1)
        #expect(store.latestProviderRefreshGenerations[.codex] == lingeringGeneration + 1)
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

        #expect(await runner.isEmpty)
        #expect(store.rollingWindowAutoStartStatus[.claude] ==
            "Skipped: selected account cannot be pinged through ambient CLI.")
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
        accountEmail: String? = nil,
        provider: UsageProvider = .codex,
        updatedAt: Date) -> UsageSnapshot
    {
        UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            updatedAt: updatedAt,
            identity: accountEmail.map {
                ProviderIdentitySnapshot(
                    providerID: provider,
                    accountEmail: $0,
                    accountOrganization: nil,
                    loginMethod: nil)
            })
    }

    private static func liveSystemCodexAccount(email: String) -> ObservedSystemCodexAccount {
        ObservedSystemCodexAccount(
            email: email,
            codexHomePath: "/tmp/codexbar-live-system",
            observedAt: Date(),
            identity: CodexIdentityResolver.resolve(accountId: nil, email: email))
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
