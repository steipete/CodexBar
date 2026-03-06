import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite
struct UsageStorePlanUtilizationTests {
    @Test
    func codexUsesProviderCostWhenAvailable() throws {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 25,
                limit: 100,
                currencyCode: "USD",
                period: "Monthly",
                resetsAt: nil,
                updatedAt: Date()),
            updatedAt: Date())
        let credits = CreditsSnapshot(remaining: 0, events: [], updatedAt: Date())

        let percent = UsageStore.planHistoryMonthlyUsedPercent(
            provider: .codex,
            snapshot: snapshot,
            credits: credits)

        #expect(try abs(#require(percent) - 25) < 0.001)
    }

    @Test
    func claudeIgnoresProviderCostForMonthlyHistory() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 40,
                limit: 100,
                currencyCode: "USD",
                period: "Monthly",
                resetsAt: nil,
                updatedAt: Date()),
            updatedAt: Date())

        let percent = UsageStore.planHistoryMonthlyUsedPercent(
            provider: .claude,
            snapshot: snapshot,
            credits: nil)

        #expect(percent == nil)
    }

    @Test
    func codexFallsBackToCredits() throws {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "free")
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: identity)
        let credits = CreditsSnapshot(remaining: 640, events: [], updatedAt: Date())

        let percent = UsageStore.planHistoryMonthlyUsedPercent(
            provider: .codex,
            snapshot: snapshot,
            credits: credits)

        #expect(try abs(#require(percent) - 36) < 0.001)
    }

    @Test
    func codexFreePlanWithoutFreshCreditsReturnsNil() {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "free")
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: identity)

        let percent = UsageStore.planHistoryMonthlyUsedPercent(
            provider: .codex,
            snapshot: snapshot,
            credits: nil)

        #expect(percent == nil)
    }

    @Test
    func codexPaidPlanDoesNotUseCreditsFallback() {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "plus")
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: identity)
        let credits = CreditsSnapshot(remaining: 0, events: [], updatedAt: Date())

        let percent = UsageStore.planHistoryMonthlyUsedPercent(
            provider: .codex,
            snapshot: snapshot,
            credits: credits)

        #expect(percent == nil)
    }

    @Test
    func claudeWithoutProviderCostReturnsNil() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: nil,
            updatedAt: Date())
        let credits = CreditsSnapshot(remaining: 100, events: [], updatedAt: Date())

        let percent = UsageStore.planHistoryMonthlyUsedPercent(
            provider: .claude,
            snapshot: snapshot,
            credits: credits)

        #expect(percent == nil)
    }

    @Test
    func codexWithinWindowPromotesMonthlyFromNilWithoutAppending() throws {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "free")
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: identity)
        let now = Date()
        let nilMonthly = PlanUtilizationHistorySample(
            capturedAt: now,
            dailyUsedPercent: nil,
            weeklyUsedPercent: nil,
            monthlyUsedPercent: nil)
        let monthlyValue = try #require(
            UsageStore.planHistoryMonthlyUsedPercent(
                provider: .codex,
                snapshot: snapshot,
                credits: CreditsSnapshot(remaining: 640, events: [], updatedAt: now)))
        let promotedMonthly = PlanUtilizationHistorySample(
            capturedAt: now.addingTimeInterval(300),
            dailyUsedPercent: nil,
            weeklyUsedPercent: nil,
            monthlyUsedPercent: monthlyValue)

        let initial = try #require(
            UsageStore._updatedPlanUtilizationHistoryForTesting(
                provider: .codex,
                existingHistory: [],
                sample: nilMonthly,
                now: now))
        let updated = try #require(
            UsageStore._updatedPlanUtilizationHistoryForTesting(
                provider: .codex,
                existingHistory: initial,
                sample: promotedMonthly,
                now: now.addingTimeInterval(300)))

        #expect(updated.count == 1)
        let monthly = updated.last?.monthlyUsedPercent
        #expect(monthly != nil)
        #expect(abs((monthly ?? 0) - 36) < 0.001)
    }

    @Test
    func codexWithinWindowIgnoresNilMonthlyAfterKnownValue() throws {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "free")
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: identity)
        let now = Date()
        let monthlyValue = try #require(
            UsageStore.planHistoryMonthlyUsedPercent(
                provider: .codex,
                snapshot: snapshot,
                credits: CreditsSnapshot(remaining: 640, events: [], updatedAt: now)))
        let knownMonthly = PlanUtilizationHistorySample(
            capturedAt: now,
            dailyUsedPercent: nil,
            weeklyUsedPercent: nil,
            monthlyUsedPercent: monthlyValue)
        let nilMonthly = PlanUtilizationHistorySample(
            capturedAt: now.addingTimeInterval(300),
            dailyUsedPercent: nil,
            weeklyUsedPercent: nil,
            monthlyUsedPercent: nil)

        let initial = try #require(
            UsageStore._updatedPlanUtilizationHistoryForTesting(
                provider: .codex,
                existingHistory: [],
                sample: knownMonthly,
                now: now))
        let updated = UsageStore._updatedPlanUtilizationHistoryForTesting(
            provider: .codex,
            existingHistory: initial,
            sample: nilMonthly,
            now: now.addingTimeInterval(300))

        #expect(updated == nil)
        #expect(initial.count == 1)
        let monthly = initial.last?.monthlyUsedPercent
        #expect(monthly != nil)
        #expect(abs((monthly ?? 0) - 36) < 0.001)
    }

    @Test
    func trimsHistoryToExpandedRetentionLimit() throws {
        let maxSamples = UsageStore._planUtilizationMaxSamplesForTesting
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var history: [PlanUtilizationHistorySample] = []

        for offset in 0..<maxSamples {
            history.append(PlanUtilizationHistorySample(
                capturedAt: base.addingTimeInterval(Double(offset) * 3600),
                dailyUsedPercent: Double(offset % 100),
                weeklyUsedPercent: nil,
                monthlyUsedPercent: nil))
        }

        let appended = PlanUtilizationHistorySample(
            capturedAt: base.addingTimeInterval(Double(maxSamples) * 3600),
            dailyUsedPercent: 50,
            weeklyUsedPercent: 60,
            monthlyUsedPercent: 70)

        let updated = try #require(
            UsageStore._updatedPlanUtilizationHistoryForTesting(
                provider: .codex,
                existingHistory: history,
                sample: appended,
                now: appended.capturedAt))

        #expect(updated.count == maxSamples)
        #expect(updated.first?.capturedAt == history[1].capturedAt)
        #expect(updated.last == appended)
    }

    @MainActor
    @Test
    func dailyModelLeftAlignsSparseHistory() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 6)))
        let samples = [
            PlanUtilizationHistorySample(
                capturedAt: now,
                dailyUsedPercent: 20,
                weeklyUsedPercent: 35,
                monthlyUsedPercent: 20),
            PlanUtilizationHistorySample(
                capturedAt: now.addingTimeInterval(-24 * 3600),
                dailyUsedPercent: 48,
                weeklyUsedPercent: 48,
                monthlyUsedPercent: 30),
            PlanUtilizationHistorySample(
                capturedAt: now.addingTimeInterval(-2 * 24 * 3600),
                dailyUsedPercent: 62,
                weeklyUsedPercent: 62,
                monthlyUsedPercent: 40),
        ]

        let model = try #require(
            PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                periodRawValue: "daily",
                samples: samples,
                provider: .codex))

        #expect(model.pointCount == 3)
        #expect(model.axisIndexes == [0, 2])
        #expect(model.xDomain == -0.5...29.5)
    }

    @MainActor
    @Test
    func weeklyModelPacksExistingPeriodsWithoutPlaceholderGaps() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 6)))
        let samples = [
            PlanUtilizationHistorySample(
                capturedAt: now,
                dailyUsedPercent: 10,
                weeklyUsedPercent: 35,
                monthlyUsedPercent: 20),
            PlanUtilizationHistorySample(
                capturedAt: now.addingTimeInterval(-7 * 24 * 3600),
                dailyUsedPercent: 20,
                weeklyUsedPercent: 48,
                monthlyUsedPercent: 30),
            PlanUtilizationHistorySample(
                capturedAt: now.addingTimeInterval(-14 * 24 * 3600),
                dailyUsedPercent: 30,
                weeklyUsedPercent: 62,
                monthlyUsedPercent: 40),
        ]

        let model = try #require(
            PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                periodRawValue: "weekly",
                samples: samples,
                provider: .codex))

        #expect(model.pointCount == 3)
        #expect(model.axisIndexes == [2])
        #expect(model.xDomain == -0.5...23.5)
    }

    @MainActor
    @Test
    func monthlyModelShowsExpandedTwoYearWindow() throws {
        let calendar = Calendar(identifier: .gregorian)
        let start = try #require(calendar.date(from: DateComponents(year: 2024, month: 1, day: 1)))
        var samples: [PlanUtilizationHistorySample] = []

        for monthOffset in 0..<30 {
            let date = try #require(calendar.date(byAdding: .month, value: monthOffset, to: start))
            samples.append(PlanUtilizationHistorySample(
                capturedAt: date,
                dailyUsedPercent: nil,
                weeklyUsedPercent: nil,
                monthlyUsedPercent: Double((monthOffset % 10) * 10)))
        }

        let model = try #require(
            PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                periodRawValue: "monthly",
                samples: samples,
                provider: .codex))

        #expect(model.pointCount == 24)
        #expect(model.axisIndexes == [23])
        #expect(model.xDomain == -0.5...23.5)
    }
}
