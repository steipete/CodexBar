import CodexBarCore
import Foundation
import Observation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct ClaudeDailyRoutinesSettingsTests {
    private final class ObservationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            self.lock.lock()
            self.value = true
            self.lock.unlock()
        }

        func get() -> Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.value
        }
    }

    @Test
    func `visibility defaults on persists and refreshes only menus`() async throws {
        let suite = "ClaudeDailyRoutinesSettingsTests-visibility"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(store.claudeDailyRoutinesUsageVisible)
        let backgroundRevision = store.backgroundWorkSettingsRevision
        let menuDidChange = ObservationFlag()
        withObservationTracking {
            _ = store.menuObservationToken
        } onChange: {
            menuDidChange.set()
        }
        store.claudeDailyRoutinesUsageVisible = false
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.backgroundWorkSettingsRevision == backgroundRevision)
        #expect(menuDidChange.get())

        let reloaded = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        #expect(reloaded.claudeDailyRoutinesUsageVisible == false)
    }
}

struct ClaudeDailyRoutinesMenuCardTests {
    @Test
    func `visibility hides only the daily routines bar`() throws {
        let now = Date()
        let identity = ProviderIdentitySnapshot(
            providerID: .claude,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Max")
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 2,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 8,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(7200),
                resetDescription: nil),
            tertiary: RateWindow(
                usedPercent: 16,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(7800),
                resetDescription: nil),
            extraRateWindows: [
                NamedRateWindow(
                    id: "claude-weekly-scoped-fable",
                    title: "Fable only",
                    window: RateWindow(
                        usedPercent: 11,
                        windowMinutes: 10080,
                        resetsAt: now.addingTimeInterval(8600),
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "claude-routines",
                    title: "Daily Routines",
                    window: RateWindow(
                        usedPercent: 7,
                        windowMinutes: 10080,
                        resetsAt: now.addingTimeInterval(9200),
                        resetDescription: nil)),
            ],
            updatedAt: now,
            identity: identity)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        func makeModel(showOptionalUsage: Bool, routinesVisible: Bool) -> UsageMenuCardView.Model {
            UsageMenuCardView.Model.make(.init(
                provider: .claude,
                metadata: metadata,
                snapshot: snapshot,
                credits: nil,
                creditsError: nil,
                dashboard: nil,
                dashboardError: nil,
                tokenSnapshot: nil,
                tokenError: nil,
                account: AccountInfo(email: "codex@example.com", plan: "plus"),
                isRefreshing: false,
                lastError: nil,
                usageBarsShowUsed: false,
                resetTimeDisplayStyle: .countdown,
                tokenCostUsageEnabled: false,
                showOptionalCreditsAndExtraUsage: showOptionalUsage,
                claudeDailyRoutinesUsageVisible: routinesVisible,
                hidePersonalInfo: false,
                now: now))
        }

        let visibleModel = makeModel(showOptionalUsage: true, routinesVisible: true)
        #expect(visibleModel.metrics.map(\.title) == [
            "Session",
            "Weekly",
            "Sonnet",
            "Fable only",
            "Daily Routines",
        ])

        let providerHiddenModel = makeModel(showOptionalUsage: true, routinesVisible: false)
        #expect(providerHiddenModel.metrics.map(\.title) == ["Session", "Weekly", "Sonnet", "Fable only"])

        let globalHiddenModel = makeModel(showOptionalUsage: false, routinesVisible: true)
        #expect(globalHiddenModel.metrics.map(\.title) == ["Session", "Weekly", "Sonnet", "Fable only"])
    }
}
