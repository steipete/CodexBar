import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension UsageStorePlanUtilizationTests {
    @MainActor
    @Test
    func `claude weekly celebration ignores transient zero when reset boundary is unchanged`() async {
        let store = Self.makeStore()
        let accountLabel = "claude-weekly-transient-zero@example.com"
        let recorder = WeeklyLimitResetEventRecorder(provider: .claude, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionReset = firstDate.addingTimeInterval(5 * 3600)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)

        func snapshot(weeklyUsed: Double, weeklyReset: Date, updatedAt: Date) -> UsageSnapshot {
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 14,
                    windowMinutes: 300,
                    resetsAt: sessionReset,
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: weeklyUsed,
                    windowMinutes: 10080,
                    resetsAt: weeklyReset,
                    resetDescription: nil),
                updatedAt: updatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .claude,
                    accountEmail: accountLabel,
                    accountOrganization: nil,
                    loginMethod: "max"))
        }

        let before = snapshot(
            weeklyUsed: 86,
            weeklyReset: weeklyReset,
            updatedAt: firstDate)
        // Bogus near-zero probe sample: usage drops to 0 but the reset boundary is unchanged.
        let transientZero = snapshot(
            weeklyUsed: 0,
            weeklyReset: weeklyReset,
            updatedAt: firstDate.addingTimeInterval(120))
        // Genuine reset: usage is 0 and the boundary has advanced by a full week.
        let realReset = snapshot(
            weeklyUsed: 0,
            weeklyReset: weeklyReset.addingTimeInterval(7 * 24 * 3600),
            updatedAt: firstDate.addingTimeInterval(180))

        await store.recordPlanUtilizationHistorySample(provider: .claude, snapshot: before, now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .claude, snapshot: transientZero, now: transientZero.updatedAt)
        #expect(recorder.events.isEmpty)

        await store.recordPlanUtilizationHistorySample(provider: .claude, snapshot: realReset, now: realReset.updatedAt)
        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.usedPercent == 0)
    }
}
