import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension UsageStorePlanUtilizationTests {
    @MainActor
    @Test
    func `codex weekly steady low usage does not create a reset candidate`() async throws {
        let store = Self.makeStore()
        let accountLabel = "codex-weekly-steady-low@example.com"
        let ownerKey = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "fixture-codex-weekly-steady-low"),
            accountEmail: accountLabel))
        let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let firstDate = Date(timeIntervalSince1970: 1_701_400_000)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)
        for offset in [TimeInterval(0), 60, 120] {
            let snapshot = codexWeeklyResetSnapshot(
                accountLabel: accountLabel,
                usedPercent: 3,
                resetsAt: weeklyReset,
                updatedAt: firstDate.addingTimeInterval(offset))
            await store.recordPlanUtilizationHistorySample(
                provider: .codex,
                snapshot: snapshot,
                codexLimitResetOwnerKey: ownerKey,
                now: snapshot.updatedAt)
        }

        #expect(recorder.events.isEmpty)
        #expect(store.weeklyLimitResetDetectorStates.values.first?.pendingLowConfirmation == false)
    }

    @MainActor
    @Test
    func `codex weekly six to five percent drift does not celebrate`() async throws {
        let store = Self.makeStore()
        let accountLabel = "codex-weekly-small-drift@example.com"
        let ownerKey = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "fixture-codex-weekly-small-drift"),
            accountEmail: accountLabel))
        let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let firstDate = Date(timeIntervalSince1970: 1_701_450_000)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)
        for (offset, usedPercent) in [(TimeInterval(0), 6.0), (60, 5.0), (120, 5.0)] {
            let snapshot = codexWeeklyResetSnapshot(
                accountLabel: accountLabel,
                usedPercent: usedPercent,
                resetsAt: weeklyReset,
                updatedAt: firstDate.addingTimeInterval(offset))
            await store.recordPlanUtilizationHistorySample(
                provider: .codex,
                snapshot: snapshot,
                codexLimitResetOwnerKey: ownerKey,
                now: snapshot.updatedAt)
        }

        #expect(recorder.events.isEmpty)
        #expect(store.weeklyLimitResetDetectorStates.values.first?.pendingLowConfirmation == false)
    }

    @MainActor
    @Test
    func `codex weekly unchanged boundary candidate can start at two percent and confirms later`() async throws {
        let store = Self.makeStore()
        let accountLabel = "codex-weekly-delayed-confirmation@example.com"
        let ownerKey = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "fixture-codex-weekly-delayed-confirmation"),
            accountEmail: accountLabel))
        let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let firstDate = Date(timeIntervalSince1970: 1_701_500_000)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)
        let before = codexWeeklyResetSnapshot(
            accountLabel: accountLabel,
            usedPercent: 86,
            resetsAt: weeklyReset,
            updatedAt: firstDate)
        let candidate = codexWeeklyResetSnapshot(
            accountLabel: accountLabel,
            usedPercent: 2,
            resetsAt: weeklyReset,
            updatedAt: firstDate.addingTimeInterval(60))
        let tooSoon = codexWeeklyResetSnapshot(
            accountLabel: accountLabel,
            usedPercent: 2,
            resetsAt: weeklyReset,
            updatedAt: firstDate.addingTimeInterval(119))
        let confirmed = codexWeeklyResetSnapshot(
            accountLabel: accountLabel,
            usedPercent: 2,
            resetsAt: weeklyReset,
            updatedAt: firstDate.addingTimeInterval(120))

        for snapshot in [before, candidate, tooSoon] {
            await store.recordPlanUtilizationHistorySample(
                provider: .codex,
                snapshot: snapshot,
                codexLimitResetOwnerKey: ownerKey,
                now: snapshot.updatedAt)
        }
        #expect(recorder.events.isEmpty)
        #expect(store.weeklyLimitResetDetectorStates.values.first?.pendingLowConfirmation == true)

        store.weeklyLimitResetDetectorStates = UsageStore.loadWeeklyLimitResetDetectorStates(
            from: store.settings.userDefaults)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: confirmed,
            codexLimitResetOwnerKey: ownerKey,
            now: confirmed.updatedAt)

        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.usedPercent == 2)

        for snapshot in [
            codexWeeklyResetSnapshot(
                accountLabel: accountLabel,
                usedPercent: 3,
                resetsAt: weeklyReset,
                updatedAt: firstDate.addingTimeInterval(180)),
            codexWeeklyResetSnapshot(
                accountLabel: accountLabel,
                usedPercent: 0,
                resetsAt: weeklyReset,
                updatedAt: firstDate.addingTimeInterval(240)),
        ] {
            await store.recordPlanUtilizationHistorySample(
                provider: .codex,
                snapshot: snapshot,
                codexLimitResetOwnerKey: ownerKey,
                now: snapshot.updatedAt)
        }
        #expect(recorder.events.count == 1)
    }

    @MainActor
    @Test
    func `codex weekly candidate expires and is cancelled by a plan change`() async throws {
        let accountLabel = "codex-weekly-candidate-lifetime@example.com"
        let ownerKey = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "fixture-codex-weekly-candidate-lifetime"),
            accountEmail: accountLabel))
        let firstDate = Date(timeIntervalSince1970: 1_701_700_000)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)

        for (laterPlan, laterOffset) in [
            ("pro", TimeInterval(60 + 30 * 60 + 1)),
            ("plus", TimeInterval(120)),
        ] {
            let store = Self.makeStore()
            let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
            defer { recorder.invalidate() }
            let before = codexWeeklyResetSnapshot(
                accountLabel: accountLabel,
                usedPercent: 86,
                resetsAt: weeklyReset,
                updatedAt: firstDate,
                loginMethod: "pro")
            let candidate = codexWeeklyResetSnapshot(
                accountLabel: accountLabel,
                usedPercent: 0.5,
                resetsAt: weeklyReset,
                updatedAt: firstDate.addingTimeInterval(60),
                loginMethod: "pro")
            let later = codexWeeklyResetSnapshot(
                accountLabel: accountLabel,
                usedPercent: 2,
                resetsAt: weeklyReset,
                updatedAt: firstDate.addingTimeInterval(laterOffset),
                loginMethod: laterPlan)

            for snapshot in [before, candidate, later] {
                await store.recordPlanUtilizationHistorySample(
                    provider: .codex,
                    snapshot: snapshot,
                    codexLimitResetOwnerKey: ownerKey,
                    now: snapshot.updatedAt)
            }

            #expect(recorder.events.isEmpty)
            #expect(store.weeklyLimitResetDetectorStates.values.first?.pendingLowConfirmation == false)
        }
    }

    @MainActor
    @Test
    func `codex weekly rebound cancels the old candidate before a later crossing starts a new one`() async throws {
        let store = Self.makeStore()
        let accountLabel = "codex-weekly-candidate-rebound@example.com"
        let ownerKey = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "fixture-codex-weekly-candidate-rebound"),
            accountEmail: accountLabel))
        let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }
        let firstDate = Date(timeIntervalSince1970: 1_701_800_000)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)

        for snapshot in [
            codexWeeklyResetSnapshot(
                accountLabel: accountLabel,
                usedPercent: 86,
                resetsAt: weeklyReset,
                updatedAt: firstDate),
            codexWeeklyResetSnapshot(
                accountLabel: accountLabel,
                usedPercent: 0.5,
                resetsAt: weeklyReset,
                updatedAt: firstDate.addingTimeInterval(60)),
        ] {
            await store.recordPlanUtilizationHistorySample(
                provider: .codex,
                snapshot: snapshot,
                codexLimitResetOwnerKey: ownerKey,
                now: snapshot.updatedAt)
        }
        #expect(store.weeklyLimitResetDetectorStates.values.first?.pendingLowConfirmation == true)

        let rebound = codexWeeklyResetSnapshot(
            accountLabel: accountLabel,
            usedPercent: 30,
            resetsAt: weeklyReset,
            updatedAt: firstDate.addingTimeInterval(120))
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: rebound,
            codexLimitResetOwnerKey: ownerKey,
            now: rebound.updatedAt)
        #expect(store.weeklyLimitResetDetectorStates.values.first?.pendingLowConfirmation == false)

        let laterCrossing = codexWeeklyResetSnapshot(
            accountLabel: accountLabel,
            usedPercent: 2,
            resetsAt: weeklyReset,
            updatedAt: firstDate.addingTimeInterval(180))
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: laterCrossing,
            codexLimitResetOwnerKey: ownerKey,
            now: laterCrossing.updatedAt)

        #expect(recorder.events.isEmpty)
        #expect(store.weeklyLimitResetDetectorStates.values.first?.pendingLowConfirmation == true)
        #expect(store.weeklyLimitResetDetectorStates.values.first?.pendingLowObservedAt == laterCrossing.updatedAt)
    }

    @MainActor
    @Test
    func `codex weekly candidate requires a known stable plan and boundary`() async throws {
        let accountLabel = "codex-weekly-candidate-evidence@example.com"
        let ownerKey = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "fixture-codex-weekly-candidate-evidence"),
            accountEmail: accountLabel))
        let firstDate = Date(timeIntervalSince1970: 1_701_850_000)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)

        for (loginMethod, laterBoundary) in [
            (nil, weeklyReset),
            ("pro", weeklyReset.addingTimeInterval(90)),
        ] as [(String?, Date)] {
            let store = Self.makeStore()
            let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
            defer { recorder.invalidate() }
            for snapshot in [
                codexWeeklyResetSnapshot(
                    accountLabel: accountLabel,
                    usedPercent: 86,
                    resetsAt: weeklyReset,
                    updatedAt: firstDate,
                    loginMethod: loginMethod),
                codexWeeklyResetSnapshot(
                    accountLabel: accountLabel,
                    usedPercent: 0.5,
                    resetsAt: weeklyReset,
                    updatedAt: firstDate.addingTimeInterval(60),
                    loginMethod: loginMethod),
                codexWeeklyResetSnapshot(
                    accountLabel: accountLabel,
                    usedPercent: 2,
                    resetsAt: laterBoundary,
                    updatedAt: firstDate.addingTimeInterval(120),
                    loginMethod: loginMethod),
            ] {
                await store.recordPlanUtilizationHistorySample(
                    provider: .codex,
                    snapshot: snapshot,
                    codexLimitResetOwnerKey: ownerKey,
                    now: snapshot.updatedAt)
            }

            #expect(recorder.events.isEmpty)
            #expect(store.weeklyLimitResetDetectorStates.values.first?.pendingLowConfirmation == false)
        }
    }

    @MainActor
    @Test
    func `codex weekly candidate cannot be confirmed by another owner`() async throws {
        let store = Self.makeStore()
        let accountLabel = "codex-weekly-candidate-owner@example.com"
        let ownerA = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "fixture-codex-weekly-candidate-owner-a"),
            accountEmail: accountLabel))
        let ownerB = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "fixture-codex-weekly-candidate-owner-b"),
            accountEmail: accountLabel))
        let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }
        let firstDate = Date(timeIntervalSince1970: 1_701_875_000)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)

        for snapshot in [
            codexWeeklyResetSnapshot(
                accountLabel: accountLabel,
                usedPercent: 86,
                resetsAt: weeklyReset,
                updatedAt: firstDate),
            codexWeeklyResetSnapshot(
                accountLabel: accountLabel,
                usedPercent: 0.5,
                resetsAt: weeklyReset,
                updatedAt: firstDate.addingTimeInterval(60)),
        ] {
            await store.recordPlanUtilizationHistorySample(
                provider: .codex,
                snapshot: snapshot,
                codexLimitResetOwnerKey: ownerA,
                now: snapshot.updatedAt)
        }

        let otherOwnerLow = codexWeeklyResetSnapshot(
            accountLabel: accountLabel,
            usedPercent: 2,
            resetsAt: weeklyReset,
            updatedAt: firstDate.addingTimeInterval(120))
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: otherOwnerLow,
            codexLimitResetOwnerKey: ownerB,
            now: otherOwnerLow.updatedAt)
        #expect(recorder.events.isEmpty)

        let returningOwnerLow = codexWeeklyResetSnapshot(
            accountLabel: accountLabel,
            usedPercent: 2,
            resetsAt: weeklyReset,
            updatedAt: firstDate.addingTimeInterval(180))
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: returningOwnerLow,
            codexLimitResetOwnerKey: ownerA,
            now: returningOwnerLow.updatedAt)

        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.usedPercent == 2)
    }

    @MainActor
    @Test
    func `codex weekly advanced boundary celebrates a reset already used to two percent`() async throws {
        let store = Self.makeStore()
        let accountLabel = "codex-weekly-two-percent@example.com"
        let ownerKey = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "fixture-codex-weekly-two-percent"),
            accountEmail: accountLabel))
        let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let firstDate = Date(timeIntervalSince1970: 1_701_900_000)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)
        let nextWeeklyReset = weeklyReset.addingTimeInterval(7 * 24 * 3600)
        let before = codexWeeklyResetSnapshot(
            accountLabel: accountLabel,
            usedPercent: 86,
            resetsAt: weeklyReset,
            updatedAt: firstDate)
        let reset = codexWeeklyResetSnapshot(
            accountLabel: accountLabel,
            usedPercent: 2,
            resetsAt: nextWeeklyReset,
            updatedAt: firstDate.addingTimeInterval(60))

        for snapshot in [before, reset] {
            await store.recordPlanUtilizationHistorySample(
                provider: .codex,
                snapshot: snapshot,
                codexLimitResetOwnerKey: ownerKey,
                now: snapshot.updatedAt)
        }

        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.usedPercent == 2)
    }

    @MainActor
    @Test
    func `codex weekly advanced boundary reset range is capped at five percent`() async throws {
        let firstDate = Date(timeIntervalSince1970: 1_701_950_000)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)
        let nextWeeklyReset = weeklyReset.addingTimeInterval(7 * 24 * 3600)

        for (usedPercent, expectedEventCount) in [(5.0, 1), (5.01, 0)] {
            let store = Self.makeStore()
            let accountLabel = "codex-weekly-threshold-\(usedPercent)@example.com"
            let ownerKey = try #require(CodexLimitResetOwnerKey(
                identity: .providerAccount(id: "fixture-codex-weekly-threshold-\(usedPercent)"),
                accountEmail: accountLabel))
            let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
            defer { recorder.invalidate() }

            for snapshot in [
                codexWeeklyResetSnapshot(
                    accountLabel: accountLabel,
                    usedPercent: 86,
                    resetsAt: weeklyReset,
                    updatedAt: firstDate),
                codexWeeklyResetSnapshot(
                    accountLabel: accountLabel,
                    usedPercent: usedPercent,
                    resetsAt: nextWeeklyReset,
                    updatedAt: firstDate.addingTimeInterval(60)),
            ] {
                await store.recordPlanUtilizationHistorySample(
                    provider: .codex,
                    snapshot: snapshot,
                    codexLimitResetOwnerKey: ownerKey,
                    now: snapshot.updatedAt)
            }

            #expect(recorder.events.count == expectedEventCount)
        }
    }
}

private func codexWeeklyResetSnapshot(
    accountLabel: String,
    usedPercent: Double,
    resetsAt: Date?,
    updatedAt: Date,
    loginMethod: String? = "test") -> UsageSnapshot
{
    UsageSnapshot(
        primary: RateWindow(
            usedPercent: usedPercent,
            windowMinutes: 10080,
            resetsAt: resetsAt,
            resetDescription: nil),
        secondary: RateWindow(
            usedPercent: 14,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: nil),
        updatedAt: updatedAt,
        identity: ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: accountLabel,
            accountOrganization: nil,
            loginMethod: loginMethod))
}
