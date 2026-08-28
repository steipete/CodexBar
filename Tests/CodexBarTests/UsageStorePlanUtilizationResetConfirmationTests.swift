import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension UsageStorePlanUtilizationTests {
    @MainActor
    @Test
    func `identity-less Claude reset celebrations require a second low sample`() async throws {
        let store = Self.makeStore()
        let sessionRecorder = SessionLimitResetEventRecorder(provider: .claude, accountLabel: nil)
        let weeklyRecorder = WeeklyLimitResetEventRecorder(provider: .claude, accountLabel: nil)
        defer {
            sessionRecorder.invalidate()
            weeklyRecorder.invalidate()
        }

        let firstDate = Date(timeIntervalSince1970: 1_780_000_000)
        let firstSessionBoundary = firstDate.addingTimeInterval(60 * 60)
        let firstWeeklyBoundary = firstDate.addingTimeInterval(3 * 24 * 60 * 60)

        func snapshot(
            sessionUsed: Double,
            weeklyUsed: Double,
            sessionBoundary: Date,
            weeklyBoundary: Date,
            updatedAt: Date) -> UsageSnapshot
        {
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: sessionUsed,
                    windowMinutes: 300,
                    resetsAt: sessionBoundary,
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: weeklyUsed,
                    windowMinutes: 10080,
                    resetsAt: weeklyBoundary,
                    resetDescription: nil),
                updatedAt: updatedAt)
        }

        let before = snapshot(
            sessionUsed: 30,
            weeklyUsed: 40,
            sessionBoundary: firstSessionBoundary,
            weeklyBoundary: firstWeeklyBoundary,
            updatedAt: firstDate)
        let apparentReset = snapshot(
            sessionUsed: 0,
            weeklyUsed: 0,
            sessionBoundary: firstSessionBoundary.addingTimeInterval(5 * 60 * 60),
            weeklyBoundary: firstWeeklyBoundary.addingTimeInterval(7 * 24 * 60 * 60),
            updatedAt: firstDate.addingTimeInterval(60))
        let recovered = try snapshot(
            sessionUsed: 31,
            weeklyUsed: 41,
            sessionBoundary: #require(apparentReset.primary?.resetsAt),
            weeklyBoundary: #require(apparentReset.secondary?.resetsAt),
            updatedAt: firstDate.addingTimeInterval(120))

        for current in [before, apparentReset, recovered] {
            await store.recordPlanUtilizationHistorySample(
                provider: .claude,
                snapshot: current,
                now: current.updatedAt)
        }
        #expect(sessionRecorder.events.isEmpty)
        #expect(weeklyRecorder.events.isEmpty)

        let reset = try snapshot(
            sessionUsed: 0,
            weeklyUsed: 0,
            sessionBoundary: #require(recovered.primary?.resetsAt).addingTimeInterval(5 * 60 * 60),
            weeklyBoundary: #require(recovered.secondary?.resetsAt).addingTimeInterval(7 * 24 * 60 * 60),
            updatedAt: firstDate.addingTimeInterval(180))
        let confirmedReset = try snapshot(
            sessionUsed: 1,
            weeklyUsed: 1,
            sessionBoundary: #require(reset.primary?.resetsAt),
            weeklyBoundary: #require(reset.secondary?.resetsAt),
            updatedAt: firstDate.addingTimeInterval(240))

        await store.recordPlanUtilizationHistorySample(provider: .claude, snapshot: reset, now: reset.updatedAt)
        #expect(sessionRecorder.events.isEmpty)
        #expect(weeklyRecorder.events.isEmpty)

        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: confirmedReset,
            now: confirmedReset.updatedAt)
        #expect(sessionRecorder.events.count == 1)
        #expect(weeklyRecorder.events.count == 1)

        let repeatedLow = try snapshot(
            sessionUsed: 0.5,
            weeklyUsed: 0.5,
            sessionBoundary: #require(confirmedReset.primary?.resetsAt),
            weeklyBoundary: #require(confirmedReset.secondary?.resetsAt),
            updatedAt: firstDate.addingTimeInterval(300))
        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: repeatedLow,
            now: repeatedLow.updatedAt)
        #expect(sessionRecorder.events.count == 1)
        #expect(weeklyRecorder.events.count == 1)
    }

    @MainActor
    @Test
    func `identity-less confirmation and identified weekly dedup compose`() async {
        let identitylessStore = Self.makeStore()
        let identitylessSessionRecorder = SessionLimitResetEventRecorder(provider: .claude, accountLabel: nil)
        let identitylessWeeklyRecorder = WeeklyLimitResetEventRecorder(provider: .claude, accountLabel: nil)
        let identifiedStore = Self.makeStore()
        let identifiedAccount = "claude-composed-reset-account"
        let identifiedWeeklyRecorder = WeeklyLimitResetEventRecorder(
            provider: .claude,
            accountLabel: identifiedAccount)
        defer {
            identitylessSessionRecorder.invalidate()
            identitylessWeeklyRecorder.invalidate()
            identifiedWeeklyRecorder.invalidate()
        }

        let start = Date(timeIntervalSince1970: 1_784_500_000)
        let firstSessionBoundary = start.addingTimeInterval(5 * 60 * 60)
        let resetSessionBoundary = firstSessionBoundary.addingTimeInterval(5 * 60 * 60)
        let weeklyBoundary = start.addingTimeInterval(4 * 24 * 60 * 60)

        func snapshot(
            accountLabel: String?,
            sessionUsed: Double,
            weeklyUsed: Double,
            sessionBoundary: Date,
            updatedAt: Date) -> UsageSnapshot
        {
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: sessionUsed,
                    windowMinutes: 300,
                    resetsAt: sessionBoundary,
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: weeklyUsed,
                    windowMinutes: 10080,
                    resetsAt: weeklyBoundary,
                    resetDescription: nil),
                updatedAt: updatedAt,
                identity: accountLabel.map {
                    ProviderIdentitySnapshot(
                        providerID: .claude,
                        accountEmail: $0,
                        accountOrganization: nil,
                        loginMethod: "test")
                })
        }

        let identitylessSnapshots = [
            snapshot(
                accountLabel: nil,
                sessionUsed: 3,
                weeklyUsed: 3,
                sessionBoundary: firstSessionBoundary,
                updatedAt: start),
            snapshot(
                accountLabel: nil,
                sessionUsed: 0,
                weeklyUsed: 0,
                sessionBoundary: resetSessionBoundary,
                updatedAt: start.addingTimeInterval(60)),
            snapshot(
                accountLabel: nil,
                sessionUsed: 3,
                weeklyUsed: 3,
                sessionBoundary: resetSessionBoundary,
                updatedAt: start.addingTimeInterval(120)),
        ]
        for current in identitylessSnapshots {
            await identitylessStore.recordPlanUtilizationHistorySample(
                provider: .claude,
                snapshot: current,
                now: current.updatedAt)
        }

        #expect(identitylessSessionRecorder.events.isEmpty)
        #expect(identitylessWeeklyRecorder.events.isEmpty)

        let identifiedWeeklyUsage = [73.0, 0.0, 73.0, 0.0]
        for (index, weeklyUsed) in identifiedWeeklyUsage.enumerated() {
            let current = snapshot(
                accountLabel: identifiedAccount,
                sessionUsed: 50,
                weeklyUsed: weeklyUsed,
                sessionBoundary: firstSessionBoundary,
                updatedAt: start.addingTimeInterval(TimeInterval(300 + index * 60)))
            await identifiedStore.recordPlanUtilizationHistorySample(
                provider: .claude,
                snapshot: current,
                now: current.updatedAt)
        }

        #expect(identifiedWeeklyRecorder.events.count == 1)
    }
}
