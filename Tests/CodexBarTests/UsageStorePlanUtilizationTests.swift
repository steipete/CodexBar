import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct UsageStorePlanUtilizationTests {
    @Test
    func `coalesces changed usage within hour into single entry`() throws {
        let calendar = Calendar(identifier: .gregorian)
        let hourStart = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 3,
            day: 17,
            hour: 10)))
        let first = planEntry(at: hourStart, usedPercent: 10)
        let second = planEntry(at: hourStart.addingTimeInterval(25 * 60), usedPercent: 35)

        let initial = try #require(
            UsageStore._updatedPlanUtilizationEntriesForTesting(
                existingEntries: [],
                entry: first))
        let updated = try #require(
            UsageStore._updatedPlanUtilizationEntriesForTesting(
                existingEntries: initial,
                entry: second))

        #expect(updated.count == 1)
        #expect(updated.last == second)
    }

    @Test
    func `changed reset boundary within hour appends new entry`() throws {
        let calendar = Calendar(identifier: .gregorian)
        let hourStart = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 3,
            day: 17,
            hour: 10)))
        let first = planEntry(
            at: hourStart.addingTimeInterval(5 * 60),
            usedPercent: 82,
            resetsAt: hourStart.addingTimeInterval(30 * 60))
        let second = planEntry(
            at: hourStart.addingTimeInterval(35 * 60),
            usedPercent: 4,
            resetsAt: hourStart.addingTimeInterval(5 * 60 * 60))

        let initial = try #require(
            UsageStore._updatedPlanUtilizationEntriesForTesting(
                existingEntries: [],
                entry: first))
        let updated = try #require(
            UsageStore._updatedPlanUtilizationEntriesForTesting(
                existingEntries: initial,
                entry: second))

        #expect(updated.count == 2)
        #expect(updated[0] == first)
        #expect(updated[1] == second)
    }

    @Test
    func `first known reset boundary within hour replaces earlier provisional peak even when usage drops`() throws {
        let calendar = Calendar(identifier: .gregorian)
        let hourStart = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 3,
            day: 17,
            hour: 10)))
        let first = planEntry(
            at: hourStart.addingTimeInterval(5 * 60),
            usedPercent: 82,
            resetsAt: nil)
        let second = planEntry(
            at: hourStart.addingTimeInterval(35 * 60),
            usedPercent: 4,
            resetsAt: hourStart.addingTimeInterval(5 * 60 * 60))

        let initial = try #require(
            UsageStore._updatedPlanUtilizationEntriesForTesting(
                existingEntries: [],
                entry: first))
        let updated = try #require(
            UsageStore._updatedPlanUtilizationEntriesForTesting(
                existingEntries: initial,
                entry: second))

        #expect(updated.count == 1)
        #expect(updated[0] == second)
    }

    @Test
    func `trims entry history to retention limit`() throws {
        let maxSamples = UsageStore._planUtilizationMaxSamplesForTesting
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var entries: [PlanUtilizationHistoryEntry] = []

        for offset in 0..<maxSamples {
            entries.append(planEntry(
                at: base.addingTimeInterval(Double(offset) * 3600),
                usedPercent: Double(offset % 100)))
        }

        let appended = planEntry(
            at: base.addingTimeInterval(Double(maxSamples) * 3600),
            usedPercent: 50)

        let updated = try #require(
            UsageStore._updatedPlanUtilizationEntriesForTesting(
                existingEntries: entries,
                entry: appended))

        #expect(updated.count == maxSamples)
        #expect(updated.first?.capturedAt == entries[1].capturedAt)
        #expect(updated.last == appended)
    }

    @MainActor
    @Test
    func `native chart shows visible series tabs only`() {
        let histories = [
            planSeries(name: .session, windowMinutes: 300, entries: [
                planEntry(at: Date(timeIntervalSince1970: 1_700_000_000), usedPercent: 20),
            ]),
            planSeries(name: .weekly, windowMinutes: 10080, entries: [
                planEntry(at: Date(timeIntervalSince1970: 1_700_086_400), usedPercent: 48),
            ]),
        ]

        let model = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            histories: histories,
            provider: .codex)

        #expect(model.visibleSeries == ["session:300", "weekly:10080"])
        #expect(model.selectedSeries == "session:300")
    }

    @MainActor
    @Test
    func `claude history tabs match current snapshot bars`() {
        let histories = [
            planSeries(name: .session, windowMinutes: 300, entries: [
                planEntry(at: Date(timeIntervalSince1970: 1_700_000_000), usedPercent: 20),
            ]),
            planSeries(name: .weekly, windowMinutes: 10080, entries: [
                planEntry(at: Date(timeIntervalSince1970: 1_700_086_400), usedPercent: 48),
            ]),
            planSeries(name: .opus, windowMinutes: 10080, entries: [
                planEntry(at: Date(timeIntervalSince1970: 1_700_086_400), usedPercent: 12),
            ]),
        ]
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 3, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 10, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_086_400),
            identity: nil)

        let model = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            histories: histories,
            provider: .claude,
            snapshot: snapshot)

        #expect(model.visibleSeries == ["session:300", "weekly:10080"])
        #expect(model.selectedSeries == "session:300")
    }

    @MainActor
    @Test
    func `session chart uses native reset boundaries and fills missing windows`() throws {
        let calendar = Calendar(identifier: .gregorian)
        let firstBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 4,
            hour: 10)))
        let thirdBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 4,
            hour: 20)))
        let histories = [
            planSeries(name: .session, windowMinutes: 300, entries: [
                planEntry(at: firstBoundary.addingTimeInterval(-30 * 60), usedPercent: 62, resetsAt: firstBoundary),
                planEntry(at: thirdBoundary.addingTimeInterval(-30 * 60), usedPercent: 20, resetsAt: thirdBoundary),
            ]),
        ]

        let model = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            selectedSeriesRawValue: "session:300",
            histories: histories,
            provider: .codex,
            referenceDate: thirdBoundary)

        #expect(model.pointCount == 3)
        #expect(model.usedPercents == [62, 0, 20])
        #expect(model.pointDates == [
            formattedBoundary(firstBoundary),
            formattedBoundary(firstBoundary.addingTimeInterval(5 * 60 * 60)),
            formattedBoundary(thirdBoundary),
        ])
    }

    @MainActor
    @Test
    func `session chart labels only day changes`() throws {
        let calendar = Calendar(identifier: .gregorian)
        let firstBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 4,
            hour: 20)))
        let thirdBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 5,
            hour: 6)))
        let histories = [
            planSeries(name: .session, windowMinutes: 300, entries: [
                planEntry(at: firstBoundary.addingTimeInterval(-30 * 60), usedPercent: 62, resetsAt: firstBoundary),
                planEntry(at: thirdBoundary.addingTimeInterval(-30 * 60), usedPercent: 20, resetsAt: thirdBoundary),
            ]),
        ]

        let model = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            selectedSeriesRawValue: "session:300",
            histories: histories,
            provider: .codex,
            referenceDate: thirdBoundary)

        #expect(model.axisIndexes == [0])
    }

    @MainActor
    @Test
    func `session chart labels every second day change`() throws {
        let calendar = Calendar(identifier: .gregorian)
        let firstBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 4,
            hour: 20)))
        let secondBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 5,
            hour: 6)))
        let thirdBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 6,
            hour: 6)))
        let fourthBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 7,
            hour: 6)))
        let histories = [
            planSeries(name: .session, windowMinutes: 300, entries: [
                planEntry(at: firstBoundary.addingTimeInterval(-30 * 60), usedPercent: 62, resetsAt: firstBoundary),
                planEntry(at: secondBoundary.addingTimeInterval(-30 * 60), usedPercent: 20, resetsAt: secondBoundary),
                planEntry(at: thirdBoundary.addingTimeInterval(-30 * 60), usedPercent: 35, resetsAt: thirdBoundary),
                planEntry(at: fourthBoundary.addingTimeInterval(-30 * 60), usedPercent: 18, resetsAt: fourthBoundary),
            ]),
        ]

        let model = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            selectedSeriesRawValue: "session:300",
            histories: histories,
            provider: .codex,
            referenceDate: fourthBoundary)

        #expect(model.axisIndexes == [0])
    }

    @MainActor
    @Test
    func `session chart drops trailing day label when it would clip at chart edge`() throws {
        let calendar = Calendar(identifier: .gregorian)
        let firstBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 4,
            hour: 20)))
        let secondBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 5,
            hour: 6)))
        let thirdBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 6,
            hour: 6)))
        let fourthBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 7,
            hour: 20)))
        let histories = [
            planSeries(name: .session, windowMinutes: 300, entries: [
                planEntry(at: firstBoundary.addingTimeInterval(-30 * 60), usedPercent: 62, resetsAt: firstBoundary),
                planEntry(at: secondBoundary.addingTimeInterval(-30 * 60), usedPercent: 20, resetsAt: secondBoundary),
                planEntry(at: thirdBoundary.addingTimeInterval(-30 * 60), usedPercent: 35, resetsAt: thirdBoundary),
                planEntry(at: fourthBoundary.addingTimeInterval(-30 * 60), usedPercent: 18, resetsAt: fourthBoundary),
            ]),
        ]

        let model = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            selectedSeriesRawValue: "session:300",
            histories: histories,
            provider: .codex,
            referenceDate: fourthBoundary)

        #expect(model.axisIndexes == [0, 10])
    }

    @MainActor
    @Test
    func `detail line shows used and wasted without provenance copy`() {
        let boundary = Date(timeIntervalSince1970: 1_710_000_000)
        let histories = [
            planSeries(name: .session, windowMinutes: 300, entries: [
                planEntry(at: boundary.addingTimeInterval(-30 * 60), usedPercent: 48, resetsAt: boundary),
            ]),
        ]

        let detail = PlanUtilizationHistoryChartMenuView._detailLineForTesting(
            selectedSeriesRawValue: "session:300",
            histories: histories,
            provider: .codex,
            referenceDate: boundary.addingTimeInterval(-1))

        #expect(detail.contains("48% used"))
        #expect(!detail.contains("Provider-reported"))
        #expect(!detail.contains("Estimated"))
        #expect(!detail.contains("wasted"))
    }

    @MainActor
    @Test
    func `detail line shows dash for missing window`() {
        let boundary = Date(timeIntervalSince1970: 1_710_000_000)
        let histories = [
            planSeries(name: .session, windowMinutes: 300, entries: [
                planEntry(at: boundary.addingTimeInterval(-30 * 60), usedPercent: 48, resetsAt: boundary),
            ]),
        ]

        let detail = PlanUtilizationHistoryChartMenuView._detailLineForTesting(
            selectedSeriesRawValue: "session:300",
            histories: histories,
            provider: .codex,
            referenceDate: boundary.addingTimeInterval(5 * 60 * 60))

        #expect(detail.contains(": -"))
    }

    @MainActor
    @Test
    func `detail line keeps zero percent for observed zero usage`() {
        let boundary = Date(timeIntervalSince1970: 1_710_000_000)
        let histories = [
            planSeries(name: .session, windowMinutes: 300, entries: [
                planEntry(at: boundary.addingTimeInterval(-30 * 60), usedPercent: 0, resetsAt: boundary),
            ]),
        ]

        let detail = PlanUtilizationHistoryChartMenuView._detailLineForTesting(
            selectedSeriesRawValue: "session:300",
            histories: histories,
            provider: .codex,
            referenceDate: boundary.addingTimeInterval(-1))

        #expect(detail.contains("0% used"))
        #expect(!detail.contains(": -"))
    }

    @MainActor
    @Test
    func `detail line uses lowercase am pm for session hover`() {
        let boundary = Date(timeIntervalSince1970: 1_710_048_000) // Mar 11, 2024 1:20 pm UTC
        let histories = [
            planSeries(name: .session, windowMinutes: 300, entries: [
                planEntry(at: boundary.addingTimeInterval(-30 * 60), usedPercent: 48, resetsAt: boundary),
            ]),
        ]

        let detail = PlanUtilizationHistoryChartMenuView._detailLineForTesting(
            selectedSeriesRawValue: "session:300",
            histories: histories,
            provider: .codex,
            referenceDate: boundary.addingTimeInterval(-1))

        #expect(detail.contains(" am") || detail.contains(" pm"))
        #expect(!detail.contains("PM"))
        #expect(!detail.contains("AM"))
    }

    @MainActor
    @Test
    func `detail line uses lowercase am pm for weekly hover`() {
        let boundary = Date(timeIntervalSince1970: 1_710_048_000) // Mar 11, 2024 1:20 pm UTC
        let histories = [
            planSeries(name: .weekly, windowMinutes: 10080, entries: [
                planEntry(at: boundary.addingTimeInterval(-30 * 60), usedPercent: 48, resetsAt: boundary),
            ]),
        ]

        let detail = PlanUtilizationHistoryChartMenuView._detailLineForTesting(
            selectedSeriesRawValue: "weekly:10080",
            histories: histories,
            provider: .codex,
            referenceDate: boundary.addingTimeInterval(-1))

        #expect(detail.contains(" am") || detail.contains(" pm"))
        #expect(!detail.contains("PM"))
        #expect(!detail.contains("AM"))
    }

    @Test
    func `chart empty state shows series specific message`() {
        let text = PlanUtilizationHistoryChartMenuView._emptyStateTextForTesting(title: "Session")
        #expect(text == "No session utilization data yet.")
    }

    @Test
    func `chart empty state shows series specific message when not refreshing`() {
        let text = PlanUtilizationHistoryChartMenuView._emptyStateTextForTesting(title: "Weekly")
        #expect(text == "No weekly utilization data yet.")
    }

    @MainActor
    @Test
    func `plan history selects current account bucket`() throws {
        let store = Self.makeStore()
        let aliceSnapshot = Self.makeSnapshot(provider: .codex, email: "alice@example.com")
        let bobSnapshot = Self.makeSnapshot(provider: .codex, email: "bob@example.com")
        let aliceKey = try #require(
            UsageStore._planUtilizationAccountKeyForTesting(
                provider: .codex,
                snapshot: aliceSnapshot))
        let bobKey = try #require(
            UsageStore._planUtilizationAccountKeyForTesting(
                provider: .codex,
                snapshot: bobSnapshot))

        let bootstrap = planSeries(name: .session, windowMinutes: 300, entries: [
            planEntry(at: Date(timeIntervalSince1970: 1_699_913_600), usedPercent: 90),
        ])
        let aliceWeekly = planSeries(name: .weekly, windowMinutes: 10080, entries: [
            planEntry(at: Date(timeIntervalSince1970: 1_700_000_000), usedPercent: 20),
        ])
        let bobWeekly = planSeries(name: .weekly, windowMinutes: 10080, entries: [
            planEntry(at: Date(timeIntervalSince1970: 1_700_086_400), usedPercent: 50),
        ])

        store.planUtilizationHistory[.codex] = PlanUtilizationHistoryBuckets(
            unscoped: [bootstrap],
            accounts: [
                aliceKey: [aliceWeekly],
                bobKey: [bobWeekly],
            ])

        store._setSnapshotForTesting(aliceSnapshot, provider: .codex)
        let aliceHistory = store.planUtilizationHistory(for: .codex)
        #expect(store.planUtilizationHistory[.codex]?.preferredAccountKey == aliceKey)
        #expect(aliceHistory == [aliceWeekly])
        #expect(store.planUtilizationHistory[.codex]?.unscoped == [bootstrap])

        store._setSnapshotForTesting(bobSnapshot, provider: .codex)
        let bobHistory = store.planUtilizationHistory(for: .codex)
        #expect(store.planUtilizationHistory[.codex]?.preferredAccountKey == bobKey)
        #expect(bobHistory == [bobWeekly])
    }

    @MainActor
    @Test
    func `plan utilization menu hides while refreshing without current snapshot`() throws {
        let store = Self.makeStore()
        let claudeKey = try #require(
            UsageStore._planUtilizationAccountKeyForTesting(
                provider: .claude,
                snapshot: Self.makeSnapshot(provider: .claude, email: "alice@example.com")))
        let weekly = planSeries(name: .weekly, windowMinutes: 10080, entries: [
            planEntry(at: Date(timeIntervalSince1970: 1_700_000_000), usedPercent: 64),
        ])
        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(
            preferredAccountKey: claudeKey,
            accounts: [
                claudeKey: [weekly],
            ])
        store.refreshingProviders.insert(.claude)
        store._setSnapshotForTesting(nil, provider: .claude)

        #expect(store.shouldShowRefreshingMenuCard(for: .claude))
        #expect(store.shouldHidePlanUtilizationMenuItem(for: .claude))
    }

    @MainActor
    @Test
    func `plan utilization menu stays visible with stored snapshot even during refresh`() throws {
        let store = Self.makeStore()
        let codexSnapshot = Self.makeSnapshot(provider: .codex, email: "alice@example.com")
        let codexKey = try #require(
            UsageStore._planUtilizationAccountKeyForTesting(
                provider: .codex,
                snapshot: codexSnapshot))
        let weekly = planSeries(name: .weekly, windowMinutes: 10080, entries: [
            planEntry(at: Date(timeIntervalSince1970: 1_700_000_000), usedPercent: 64),
        ])
        store.planUtilizationHistory[.codex] = PlanUtilizationHistoryBuckets(
            preferredAccountKey: codexKey,
            accounts: [
                codexKey: [weekly],
            ])
        store.refreshingProviders.insert(.codex)
        store._setSnapshotForTesting(codexSnapshot, provider: .codex)

        #expect(!store.shouldShowRefreshingMenuCard(for: .codex))
        #expect(!store.shouldHidePlanUtilizationMenuItem(for: .codex))
        let histories = store.planUtilizationHistory(for: .codex)
        #expect(store.planUtilizationHistory[.codex]?.preferredAccountKey == codexKey)
        #expect(histories == [weekly])
    }

    @MainActor
    @Test
    func `codex plan utilization menu hides during provider only refresh without snapshot`() {
        let store = Self.makeStore()
        store.refreshingProviders.insert(.codex)
        store._setSnapshotForTesting(nil, provider: .codex)

        #expect(store.shouldShowRefreshingMenuCard(for: .codex))
        #expect(store.shouldHidePlanUtilizationMenuItem(for: .codex))
    }

    @MainActor
    @Test
    func `record plan history persists named series from snapshot`() async {
        let store = Self.makeStore()
        let primaryReset = Date(timeIntervalSince1970: 1_710_000_000)
        let secondaryReset = Date(timeIntervalSince1970: 1_710_086_400)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 110,
                windowMinutes: 300,
                resetsAt: primaryReset,
                resetDescription: "5h"),
            secondary: RateWindow(
                usedPercent: -20,
                windowMinutes: 10080,
                resetsAt: secondaryReset,
                resetDescription: "7d"),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "alice@example.com",
                accountOrganization: nil,
                loginMethod: "plus"))
        store._setSnapshotForTesting(snapshot, provider: .codex)

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_700_000_000))

        let histories = store.planUtilizationHistory(for: .codex)
        #expect(findSeries(histories, name: .session, windowMinutes: 300)?.entries.last?.usedPercent == 100)
        #expect(findSeries(histories, name: .session, windowMinutes: 300)?.entries.last?.resetsAt == primaryReset)
        #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.last?.usedPercent == 0)
        #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.last?.resetsAt == secondaryReset)
    }

    @MainActor
    @Test
    func `record plan history keeps semantic codex lanes when durations drift`() async {
        let store = Self.makeStore()
        let primaryReset = Date(timeIntervalSince1970: 1_710_000_000)
        let secondaryReset = Date(timeIntervalSince1970: 1_710_086_400)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 18,
                windowMinutes: 360,
                resetsAt: primaryReset,
                resetDescription: "6h"),
            secondary: RateWindow(
                usedPercent: 42,
                windowMinutes: 11040,
                resetsAt: secondaryReset,
                resetDescription: "7.67d"),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "alice@example.com",
                accountOrganization: nil,
                loginMethod: "plus"))
        store._setSnapshotForTesting(snapshot, provider: .codex)

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_700_000_000))

        let histories = store.planUtilizationHistory(for: .codex)
        #expect(findSeries(histories, name: .session, windowMinutes: 360)?.entries.last?.usedPercent == 18)
        #expect(findSeries(histories, name: .session, windowMinutes: 360)?.entries.last?.resetsAt == primaryReset)
        #expect(findSeries(histories, name: .weekly, windowMinutes: 11040)?.entries.last?.usedPercent == 42)
        #expect(findSeries(histories, name: .weekly, windowMinutes: 11040)?.entries.last?.resetsAt == secondaryReset)
    }

    @MainActor
    @Test
    func `record plan history stores claude opus as separate series`() async {
        let store = Self.makeStore()
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 30, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "alice@example.com",
                accountOrganization: nil,
                loginMethod: "max"))
        store._setSnapshotForTesting(snapshot, provider: .claude)

        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_700_000_000))

        let histories = store.planUtilizationHistory(for: .claude)
        #expect(findSeries(histories, name: .session, windowMinutes: 300)?.entries.last?.usedPercent == 10)
        #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.last?.usedPercent == 20)
        #expect(findSeries(histories, name: .opus, windowMinutes: 10080)?.entries.last?.usedPercent == 30)
    }

    @MainActor
    @Test
    func `concurrent plan history writes coalesce within single hour bucket per series`() async throws {
        let store = Self.makeStore()
        let snapshot = Self.makeSnapshot(provider: .codex, email: "alice@example.com")
        store._setSnapshotForTesting(snapshot, provider: .codex)
        let calendar = Calendar(identifier: .gregorian)
        let hourStart = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 3,
            day: 17,
            hour: 10)))
        let writeTimes = [
            hourStart.addingTimeInterval(5 * 60),
            hourStart.addingTimeInterval(25 * 60),
            hourStart.addingTimeInterval(45 * 60),
        ]

        await withTaskGroup(of: Void.self) { group in
            for writeTime in writeTimes {
                group.addTask {
                    await store.recordPlanUtilizationHistorySample(
                        provider: .codex,
                        snapshot: snapshot,
                        now: writeTime)
                }
            }
        }

        let histories = try #require(store.planUtilizationHistory[.codex]?.accounts.values.first)
        #expect(findSeries(histories, name: .session, windowMinutes: 300)?.entries.count == 1)
        #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.count == 1)
    }

    @Test
    func `runtime does not load unsupported plan history file`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directoryURL = root
            .appendingPathComponent("com.steipete.codexbar", isDirectory: true)
            .appendingPathComponent("history", isDirectory: true)
        let providerURL = directoryURL.appendingPathComponent("codex.json")
        let store = PlanUtilizationHistoryStore(directoryURL: directoryURL)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true)

        let unsupportedJSON = """
        {
          "version": 999,
          "unscoped": [],
          "accounts": {}
        }
        """
        try Data(unsupportedJSON.utf8).write(to: providerURL, options: Data.WritingOptions.atomic)

        let loaded = store.load()
        #expect(loaded.isEmpty)
    }

    @Test
    func `store round trips account buckets with series entries`() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directoryURL = root
            .appendingPathComponent("com.steipete.codexbar", isDirectory: true)
            .appendingPathComponent("history", isDirectory: true)
        let store = PlanUtilizationHistoryStore(directoryURL: directoryURL)
        let buckets = PlanUtilizationHistoryBuckets(
            preferredAccountKey: "alice",
            unscoped: [
                planSeries(name: .session, windowMinutes: 300, entries: [
                    planEntry(at: Date(timeIntervalSince1970: 1_699_913_600), usedPercent: 50),
                ]),
            ],
            accounts: [
                "alice": [
                    planSeries(name: .session, windowMinutes: 300, entries: [
                        planEntry(at: Date(timeIntervalSince1970: 1_700_000_000), usedPercent: 10),
                    ]),
                    planSeries(name: .weekly, windowMinutes: 10080, entries: [
                        planEntry(at: Date(timeIntervalSince1970: 1_700_000_000), usedPercent: 20),
                    ]),
                ],
            ])

        store.save([.codex: buckets])
        let loaded = store.load()

        #expect(loaded == [.codex: buckets])
    }
}

extension UsageStorePlanUtilizationTests {
    private struct FixtureDocument: Decodable {
        let preferredAccountKey: String?
        let unscoped: [PlanUtilizationSeriesHistory]
        let accounts: [String: [PlanUtilizationSeriesHistory]]
    }

    @MainActor
    static func makeStore() -> UsageStore {
        let suiteName = "UsageStorePlanUtilizationTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create isolated UserDefaults suite for tests")
        }
        defaults.removePersistentDomain(forName: suiteName)
        let configStore = testConfigStore(suiteName: suiteName)
        let planHistoryStore = testPlanUtilizationHistoryStore(suiteName: suiteName)
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let managedStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suiteName)-managed-codex-accounts.json")
        precondition(configStore.fileURL.standardizedFileURL.path.hasPrefix(temporaryRoot))
        precondition(configStore.fileURL.standardizedFileURL != CodexBarConfigStore.defaultURL().standardizedFileURL)
        if let historyURL = planHistoryStore.directoryURL?.standardizedFileURL {
            precondition(historyURL.path.hasPrefix(temporaryRoot))
        }
        let managedStore = FileManagedCodexAccountStore(fileURL: managedStoreURL)
        try? FileManager.default.removeItem(at: managedStoreURL)
        do {
            try managedStore.storeAccounts(ManagedCodexAccountSet(
                version: FileManagedCodexAccountStore.currentVersion,
                accounts: []))
        } catch {
            fatalError("Failed to seed isolated managed Codex account store: \(error)")
        }
        let isolatedSettings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            tokenAccountStore: InMemoryTokenAccountStore())
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: isolatedSettings,
            planUtilizationHistoryStore: planHistoryStore,
            startupBehavior: .testing)
        isolatedSettings._test_managedCodexAccountStoreURL = managedStoreURL
        isolatedSettings.codexActiveSource = .liveSystem
        store.planUtilizationHistory = [:]
        return store
    }

    static func makeSnapshot(provider: UsageProvider, email: String) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: provider,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: "plus"))
    }

    static func loadPlanUtilizationFixture(named name: String) throws -> PlanUtilizationHistoryBuckets {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
        let data = try Data(contentsOf: fixtureURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(FixtureDocument.self, from: data)
        return PlanUtilizationHistoryBuckets(
            preferredAccountKey: document.preferredAccountKey,
            unscoped: document.unscoped,
            accounts: document.accounts)
    }
}

func planEntry(at capturedAt: Date, usedPercent: Double, resetsAt: Date? = nil) -> PlanUtilizationHistoryEntry {
    PlanUtilizationHistoryEntry(capturedAt: capturedAt, usedPercent: usedPercent, resetsAt: resetsAt)
}

func planSeries(
    name: PlanUtilizationSeriesName,
    windowMinutes: Int,
    entries: [PlanUtilizationHistoryEntry]) -> PlanUtilizationSeriesHistory
{
    PlanUtilizationSeriesHistory(name: name, windowMinutes: windowMinutes, entries: entries)
}

func findSeries(
    _ histories: [PlanUtilizationSeriesHistory],
    name: PlanUtilizationSeriesName,
    windowMinutes: Int) -> PlanUtilizationSeriesHistory?
{
    histories.first { $0.name == name && $0.windowMinutes == windowMinutes }
}

func formattedBoundary(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}
