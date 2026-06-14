import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct RollingWindowAutoStartReviewFixTests {
    @Test
    func `claude decision starts when model specific weekly window is exhausted`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredSessionReset = now.addingTimeInterval(-60)
        let modelSpecificExhausted = RateWindow(
            usedPercent: 100,
            windowMinutes: 7 * 24 * 60,
            resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60),
            resetDescription: nil)
        let previous = Self.snapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 5 * 60,
                resetsAt: expiredSessionReset,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 25,
                windowMinutes: 7 * 24 * 60,
                resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60),
                resetDescription: nil),
            tertiary: modelSpecificExhausted,
            provider: .claude,
            updatedAt: now.addingTimeInterval(-120))
        let current = Self.snapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 5 * 60,
                resetsAt: nil,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 25,
                windowMinutes: 7 * 24 * 60,
                resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60),
                resetDescription: nil),
            tertiary: modelSpecificExhausted,
            provider: .claude,
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
    func `OpenAI web dashboard attach updates reset snapshot and schedules expired window`() async throws {
        let settings = try Self.makeSettingsStore(suite: "RollingWindowAutoStartReviewFixTests-dashboard")
        settings.setRollingWindowAutoStartEnabled(provider: .codex, enabled: true)
        settings._test_liveSystemCodexAccount = Self.liveSystemCodexAccount(email: "codex@example.com")
        defer { settings._test_liveSystemCodexAccount = nil }
        let store = Self.makeUsageStore(settings: settings)
        let runner = ReviewFixRollingWindowPingRunner()
        store.rollingWindowAutoStartRuntime.testRunnerOverride = runner
        var refreshCount = 0
        store._test_providerRefreshOverride = { _ in
            refreshCount += 1
        }

        let now = Date()
        let expired = now.addingTimeInterval(-60)
        await store.applyOpenAIDashboard(
            Self.openAIWebDashboard(
                email: "codex@example.com",
                primaryLimit: RateWindow(
                    usedPercent: 20,
                    windowMinutes: 300,
                    resetsAt: expired,
                    resetDescription: nil),
                updatedAt: now.addingTimeInterval(-120)),
            targetEmail: "codex@example.com")
        await store.applyOpenAIDashboard(
            Self.openAIWebDashboard(
                email: "codex@example.com",
                primaryLimit: RateWindow(
                    usedPercent: 0,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: now),
            targetEmail: "codex@example.com")

        try await Self.waitForAutoStartToFinish(store: store, provider: .codex)
        #expect(await runner.count == 1)
        #expect(refreshCount == 1)
        #expect(store.lastKnownResetSnapshots[.codex]?.primary?.resetsAt == nil)
        #expect(store.rollingWindowAutoStartRuntime.attemptedResetAt[.codexLiveSystem] == expired)
    }

    @Test
    func `OpenAI web dashboard attach schedules inactive window without cached reset`() async throws {
        let settings = try Self.makeSettingsStore(suite: "RollingWindowAutoStartReviewFixTests-dashboard-no-reset")
        settings.setRollingWindowAutoStartEnabled(provider: .codex, enabled: true)
        settings._test_liveSystemCodexAccount = Self.liveSystemCodexAccount(email: "codex@example.com")
        defer { settings._test_liveSystemCodexAccount = nil }
        let store = Self.makeUsageStore(settings: settings)
        let runner = ReviewFixRollingWindowPingRunner()
        store.rollingWindowAutoStartRuntime.testRunnerOverride = runner
        var refreshCount = 0
        store._test_providerRefreshOverride = { _ in
            refreshCount += 1
        }

        await store.applyOpenAIDashboard(
            Self.openAIWebDashboard(
                email: "codex@example.com",
                primaryLimit: RateWindow(
                    usedPercent: 0,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: Date()),
            targetEmail: "codex@example.com")

        try await Self.waitForAutoStartToFinish(store: store, provider: .codex)
        #expect(await runner.count == 1)
        #expect(refreshCount == 1)
        #expect(store.rollingWindowAutoStartRuntime.attemptedInactiveWithoutReset.contains(.codexLiveSystem))
    }

    @Test
    func `decision skips inactive codex cli snapshot without previous reset`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let current = Self.snapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            provider: .codex,
            updatedAt: now)

        let decision = RollingWindowAutoStartDecision.shouldStart(
            provider: .codex,
            previousSourceLabel: nil,
            sourceLabel: "codex-cli",
            previous: nil,
            currentProviderData: current,
            now: now)

        #expect(decision == nil)
    }

    @Test
    func `decision skips inactive claude cli snapshot without previous reset`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let current = Self.snapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            provider: .claude,
            updatedAt: now)

        let decision = RollingWindowAutoStartDecision.shouldStart(
            provider: .claude,
            previousSourceLabel: nil,
            sourceLabel: "claude",
            previous: nil,
            currentProviderData: current,
            now: now)

        #expect(decision == nil)
    }

    @Test
    func `scheduler skips codex cli inactive snapshot without prior reset`() async throws {
        let settings = try Self.makeSettingsStore(suite: "RollingWindowAutoStartReviewFixTests-cli-no-reset")
        settings.setRollingWindowAutoStartEnabled(provider: .codex, enabled: true)
        let store = Self.makeUsageStore(settings: settings)
        let runner = ReviewFixRollingWindowPingRunner()
        store.rollingWindowAutoStartRuntime.testRunnerOverride = runner
        store._test_providerRefreshOverride = { _ in }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let current = Self.snapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            provider: .codex,
            updatedAt: now)

        store.scheduleRollingWindowAutoStartIfNeeded(
            provider: .codex,
            previousSourceLabel: nil,
            sourceLabel: "codex-cli",
            previousSnapshot: nil,
            currentProviderData: current,
            now: now)

        #expect(await runner.isEmpty)
        #expect(store.rollingWindowAutoStartRuntime.attemptedInactiveWithoutReset.isEmpty)
    }

    @Test
    func `decision skips active codex OpenAI web window with reset description and no reset timestamp`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = Self.snapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(-60),
                resetDescription: nil),
            provider: .codex,
            updatedAt: now.addingTimeInterval(-120))
        let current = Self.snapshot(
            primary: RateWindow(
                usedPercent: 2,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: "Resets 8:44 PM"),
            provider: .codex,
            updatedAt: now)

        let decision = RollingWindowAutoStartDecision.shouldStart(
            provider: .codex,
            previousSourceLabel: "openai-web",
            sourceLabel: "openai-web",
            previous: previous,
            currentProviderData: current,
            now: now)

        #expect(decision == nil)
    }

    @Test
    func `decision starts when current rolling window has expired timestamp and reset description`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = now.addingTimeInterval(-60)
        let previous = Self.snapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: expired, resetDescription: nil),
            provider: .codex,
            updatedAt: now.addingTimeInterval(-120))
        let current = Self.snapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: expired,
                resetDescription: "Resets 8:44 PM"),
            provider: .codex,
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
    func `scheduler verifies text only active window after ping`() async throws {
        let settings = try Self.makeSettingsStore(suite: "RollingWindowAutoStartReviewFixTests-text-verify")
        settings.setRollingWindowAutoStartEnabled(provider: .codex, enabled: true)
        let store = Self.makeUsageStore(settings: settings)
        let runner = ReviewFixRollingWindowPingRunner()
        store.rollingWindowAutoStartRuntime.testRunnerOverride = runner
        var refreshCount = 0

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        store._test_providerRefreshOverride = { _ in
            refreshCount += 1
            store.snapshots[.codex] = Self.snapshot(
                primary: RateWindow(
                    usedPercent: 2,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: "Resets 8:44 PM"),
                provider: .codex,
                updatedAt: now)
        }

        let expired = now.addingTimeInterval(-60)
        let previous = Self.snapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: expired, resetDescription: nil),
            provider: .codex,
            updatedAt: now.addingTimeInterval(-120))
        let current = Self.snapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            provider: .codex,
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
        #expect(store.rollingWindowAutoStartStatus[.codex] == nil)
    }

    @Test
    func `reset description log helper trims missing and present values`() {
        #expect(UsageStore.rollingWindowAutoStartResetDescription(nil) == "none")
        #expect(UsageStore.rollingWindowAutoStartResetDescription(
            RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: "  ")) == "none")
        #expect(UsageStore.rollingWindowAutoStartResetDescription(
            RateWindow(
                usedPercent: 2,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: " Resets 8:44 PM ")) == "Resets 8:44 PM")
    }

    @Test
    func `OpenAI web dashboard attach does not overwrite codex cli snapshot`() async throws {
        let settings = try Self.makeSettingsStore(suite: "RollingWindowAutoStartReviewFixTests-dashboard-cli")
        settings._test_liveSystemCodexAccount = Self.liveSystemCodexAccount(email: "web@example.com")
        defer { settings._test_liveSystemCodexAccount = nil }
        let store = Self.makeUsageStore(settings: settings)

        let now = Date()
        let cliReset = now.addingTimeInterval(60 * 60)
        let cliSnapshot = Self.snapshot(
            primary: RateWindow(
                usedPercent: 42,
                windowMinutes: 300,
                resetsAt: cliReset,
                resetDescription: nil),
            accountEmail: "cli@example.com",
            provider: .codex,
            updatedAt: now.addingTimeInterval(-60))
        store.snapshots[.codex] = cliSnapshot
        store.lastKnownResetSnapshots[.codex] = cliSnapshot
        store.lastSourceLabels[.codex] = "codex-cli"

        await store.applyOpenAIDashboard(
            Self.openAIWebDashboard(
                email: "web@example.com",
                primaryLimit: RateWindow(
                    usedPercent: 5,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: now),
            targetEmail: "web@example.com")

        #expect(store.openAIDashboard?.signedInEmail == "web@example.com")
        #expect(store.snapshots[.codex]?.accountEmail(for: .codex) == "cli@example.com")
        #expect(store.snapshots[.codex]?.primary?.usedPercent == 42)
        #expect(store.lastKnownResetSnapshots[.codex]?.primary?.resetsAt == cliReset)
        #expect(store.lastSourceLabels[.codex] == "codex-cli")
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
        provider: UsageProvider,
        updatedAt: Date) -> UsageSnapshot
    {
        UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            updatedAt: updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: provider,
                accountEmail: accountEmail,
                accountOrganization: nil,
                loginMethod: nil))
    }

    private static func liveSystemCodexAccount(email: String) -> ObservedSystemCodexAccount {
        ObservedSystemCodexAccount(
            email: email,
            codexHomePath: "/tmp/codexbar-live-system",
            observedAt: Date(),
            identity: CodexIdentityResolver.resolve(accountId: nil, email: email))
    }

    private static func openAIWebDashboard(
        email: String,
        primaryLimit: RateWindow,
        updatedAt: Date) -> OpenAIDashboardSnapshot
    {
        OpenAIDashboardSnapshot(
            signedInEmail: email,
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            primaryLimit: primaryLimit,
            updatedAt: updatedAt)
    }
}

private actor ReviewFixRollingWindowPingRunner: RollingWindowPingRunning {
    private(set) var count = 0
    var isEmpty: Bool {
        self.count < 1
    }

    func run(_: RollingWindowPingRequest) async throws {
        self.count += 1
    }
}
