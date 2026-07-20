import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SessionEquivalentForecastTests {
    private static let weeklyReset = Date(timeIntervalSince1970: 2_000_000_000)

    @Test
    func `uses the median of the latest seven completed active session windows`() throws {
        let fixture = Self.historyFixture(burns: [5, 4, 8, 6, 10, 12, 14, 16])

        let estimate = try #require(SessionEquivalentBurnEstimator.estimate(
            histories: fixture.histories,
            currentSessionResetsAt: fixture.currentSessionReset,
            now: fixture.currentSessionReset.addingTimeInterval(-3600)))

        #expect(estimate.sampleCount == 7)
        #expect(estimate.medianWeeklyPercentPerWindow == 10)
    }

    @Test
    func `normalizes aligned partial session observations to a full allowance`() throws {
        let fixture = Self.alignedPartialHistoryFixture()

        let estimate = try #require(SessionEquivalentBurnEstimator.estimate(
            histories: fixture.histories,
            currentSessionResetsAt: fixture.currentSessionReset,
            now: fixture.currentSessionReset.addingTimeInterval(-3600)))

        #expect(estimate.sampleCount == 3)
        #expect(estimate.medianWeeklyPercentPerWindow == 10)
    }

    @Test
    func `rejects partial sessions whose weekly burn cannot be aligned`() {
        let fixture = Self.historyFixture(samples: [
            (sessionUsedPercent: 20, weeklyBurnPercent: 2),
            (sessionUsedPercent: 40, weeklyBurnPercent: 4),
            (sessionUsedPercent: 60, weeklyBurnPercent: 6),
        ])

        #expect(SessionEquivalentBurnEstimator.estimate(
            histories: fixture.histories,
            currentSessionResetsAt: fixture.currentSessionReset,
            now: fixture.currentSessionReset.addingTimeInterval(-3600)) == nil)
    }

    @Test
    func `uses eligible boundary samples when a closer sample follows the boundary`() throws {
        let fixture = Self.straddledBoundaryHistoryFixture()

        let estimate = try #require(SessionEquivalentBurnEstimator.estimate(
            histories: fixture.histories,
            currentSessionResetsAt: fixture.currentSessionReset,
            now: fixture.currentSessionReset.addingTimeInterval(-3600)))

        #expect(estimate.sampleCount == 3)
        #expect(estimate.medianWeeklyPercentPerWindow == 10)
    }

    @Test
    func `requires three completed windows with measurable burn`() {
        let fixture = Self.historyFixture(burns: [8, 12])

        let estimate = SessionEquivalentBurnEstimator.estimate(
            histories: fixture.histories,
            currentSessionResetsAt: fixture.currentSessionReset,
            now: fixture.currentSessionReset.addingTimeInterval(-3600))

        #expect(estimate == nil)
    }

    @Test
    func `rejects zero burn and non finite division inputs`() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let session = RateWindow(
            usedPercent: 20,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(3600),
            resetDescription: nil)
        let weekly = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(2 * 24 * 3600),
            resetDescription: nil)

        #expect(SessionEquivalentForecast.make(
            sessionWindow: session,
            weeklyWindow: weekly,
            burnEstimate: SessionEquivalentBurnEstimate(
                medianWeeklyPercentPerWindow: 0,
                sampleCount: 3),
            now: now,
            workDays: nil) == nil)
        #expect(SessionEquivalentForecast.make(
            sessionWindow: session,
            weeklyWindow: weekly,
            burnEstimate: SessionEquivalentBurnEstimate(
                medianWeeklyPercentPerWindow: .infinity,
                sampleCount: 3),
            now: now,
            workDays: nil) == nil)
    }

    @Test
    func `rejects synthetic Claude session placeholder with a future reset`() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let session = RateWindow(
            usedPercent: 0,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(3600),
            resetDescription: nil,
            isSyntheticPlaceholder: true)
        let weekly = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(2 * 24 * 3600),
            resetDescription: nil)

        #expect(SessionEquivalentForecast.make(
            sessionWindow: session,
            weeklyWindow: weekly,
            burnEstimate: SessionEquivalentBurnEstimate(
                medianWeeklyPercentPerWindow: 10,
                sampleCount: 3),
            now: now,
            workDays: nil) == nil)
    }

    @Test
    func `privacy redaction preserves session equivalent detail`() throws {
        let detail = UsagePaceText.sessionEquivalentDetail(forecast: SessionEquivalentForecast(
            estimatedWindowsToExhaustWeekly: 4,
            windowsUntilReset: 9,
            sampleCount: 7,
            weeklyResetsAt: Self.weeklyReset,
            weeklyUsedPercent: 60))
        let metric = UsageMenuCardView.Model.Metric(
            id: "weekly",
            title: "Weekly",
            percent: 60,
            percentStyle: .used,
            resetText: nil,
            detailText: nil,
            detailLeftText: nil,
            detailRightText: nil,
            pacePercent: nil,
            paceOnTop: false,
            sessionEquivalentDetail: detail)

        let redacted = UsageMenuCardView.Model.redactedMetrics(
            [metric],
            provider: .claude,
            hidePersonalInfo: true)

        let redactedDetail = try #require(redacted.first?.sessionEquivalentDetail)
        #expect(redactedDetail.verdictText == detail.verdictText)
        #expect(redactedDetail.numberText == detail.numberText)
    }

    @Test
    func `floors five hour windows at exact boundaries`() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let session = RateWindow(
            usedPercent: 20,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(3600),
            resetDescription: nil)
        let burn = SessionEquivalentBurnEstimate(medianWeeklyPercentPerWindow: 10, sampleCount: 3)

        let below = try #require(SessionEquivalentForecast.make(
            sessionWindow: session,
            weeklyWindow: RateWindow(
                usedPercent: 60,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(10 * 5 * 3600 - 1),
                resetDescription: nil),
            burnEstimate: burn,
            now: now,
            workDays: nil))
        let exact = try #require(SessionEquivalentForecast.make(
            sessionWindow: session,
            weeklyWindow: RateWindow(
                usedPercent: 60,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(10 * 5 * 3600),
                resetDescription: nil),
            burnEstimate: burn,
            now: now,
            workDays: nil))

        #expect(below.windowsUntilReset == 9)
        #expect(exact.windowsUntilReset == 10)
    }

    @Test
    func `work day setting excludes weekend capacity`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 17,
            hour: 12)))
        let reset = try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 20,
            hour: 12)))
        let session = RateWindow(
            usedPercent: 20,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(3600),
            resetDescription: nil)
        let weekly = RateWindow(
            usedPercent: 60,
            windowMinutes: 10080,
            resetsAt: reset,
            resetDescription: nil)
        let burn = SessionEquivalentBurnEstimate(medianWeeklyPercentPerWindow: 10, sampleCount: 3)

        let everyDay = try #require(SessionEquivalentForecast.make(
            sessionWindow: session,
            weeklyWindow: weekly,
            burnEstimate: burn,
            now: now,
            workDays: nil,
            calendar: calendar))
        let weekdays = try #require(SessionEquivalentForecast.make(
            sessionWindow: session,
            weeklyWindow: weekly,
            burnEstimate: burn,
            now: now,
            workDays: 5,
            calendar: calendar))

        #expect(everyDay.windowsUntilReset == 14)
        #expect(weekdays.windowsUntilReset == 4)
    }

    @Test
    func `formats verdict first and number second`() {
        let early = SessionEquivalentForecast(
            estimatedWindowsToExhaustWeekly: 4,
            windowsUntilReset: 9,
            sampleCount: 7,
            weeklyResetsAt: Self.weeklyReset,
            weeklyUsedPercent: 60)
        let stranded = SessionEquivalentForecast(
            estimatedWindowsToExhaustWeekly: 10,
            windowsUntilReset: 9,
            sampleCount: 7,
            weeklyResetsAt: Self.weeklyReset,
            weeklyUsedPercent: 20)

        let earlyText = UsagePaceText.sessionEquivalentDetail(forecast: early)
        let strandedText = UsagePaceText.sessionEquivalentDetail(forecast: stranded)

        #expect(earlyText.verdictText == "Weekly can run out ≈5 windows early")
        #expect(earlyText.numberText == "≈4 full 5h windows of weekly left · 9 windows until reset")
        #expect(earlyText.verdictAccessibilityLabel == "Estimated: Weekly can run out ≈5 windows early")
        #expect(strandedText.verdictText == "Weekly cannot run out before reset at this pace")
    }

    @Test
    func `formats equality as lasting to reset and pluralizes singular windows`() {
        let equal = UsagePaceText.sessionEquivalentDetail(forecast: SessionEquivalentForecast(
            estimatedWindowsToExhaustWeekly: 2,
            windowsUntilReset: 2,
            sampleCount: 7,
            weeklyResetsAt: Self.weeklyReset,
            weeklyUsedPercent: 80))
        let singular = UsagePaceText.sessionEquivalentDetail(forecast: SessionEquivalentForecast(
            estimatedWindowsToExhaustWeekly: 1,
            windowsUntilReset: 2,
            sampleCount: 7,
            weeklyResetsAt: Self.weeklyReset,
            weeklyUsedPercent: 90))
        let close = UsagePaceText.sessionEquivalentDetail(forecast: SessionEquivalentForecast(
            estimatedWindowsToExhaustWeekly: 8.6,
            windowsUntilReset: 9,
            sampleCount: 7,
            weeklyResetsAt: Self.weeklyReset,
            weeklyUsedPercent: 14))

        #expect(equal.verdictText == "Weekly cannot run out before reset at this pace")
        #expect(singular.numberText == "≈1 full 5h window of weekly left · 2 windows until reset")
        #expect(singular.verdictText == "Weekly can run out ≈1 window early")
        #expect(close.numberText == "≈8 full 5h windows of weekly left · 9 windows until reset")
        #expect(close.verdictText == "Weekly can run out ≈1 window early")
    }

    @Test
    func `verdict uses fractional capacity while number line shows full windows`() {
        let detail = UsagePaceText.sessionEquivalentDetail(forecast: SessionEquivalentForecast(
            estimatedWindowsToExhaustWeekly: 0.5,
            windowsUntilReset: 0,
            availableWindowsUntilReset: 0.8,
            sampleCount: 7,
            weeklyResetsAt: Self.weeklyReset,
            weeklyUsedPercent: 95))

        #expect(detail.verdictText == "Weekly can run out ≈1 window early")
        #expect(detail.numberText == "≈0 full 5h windows of weekly left · 0 windows until reset")
    }

    @Test
    func `reset tolerance compares actual distance across bucket boundaries`() throws {
        let fixture = Self.historyFixture(burns: [4, 6, 8])
        let session = PlanUtilizationSeriesHistory(
            name: .session,
            windowMinutes: 300,
            entries: fixture.histories[0].entries.enumerated().map { index, entry in
                planEntry(
                    at: entry.capturedAt,
                    usedPercent: entry.usedPercent,
                    resetsAt: entry.resetsAt?.addingTimeInterval(index.isMultiple(of: 2) ? 59 : 61))
            })
        let weekly = PlanUtilizationSeriesHistory(
            name: .weekly,
            windowMinutes: 10080,
            entries: fixture.histories[1].entries.enumerated().map { index, entry in
                planEntry(
                    at: entry.capturedAt,
                    usedPercent: entry.usedPercent,
                    resetsAt: entry.resetsAt?.addingTimeInterval(index.isMultiple(of: 2) ? 59 : 61))
            })

        let estimate = try #require(SessionEquivalentBurnEstimator.estimate(
            histories: [session, weekly],
            currentSessionResetsAt: fixture.currentSessionReset,
            now: fixture.currentSessionReset.addingTimeInterval(-3600)))

        #expect(estimate.sampleCount == 3)
        #expect(estimate.medianWeeklyPercentPerWindow == 6)
    }

    @Test
    func `rejects hostile dates percentages and unsorted history`() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let session = RateWindow(
            usedPercent: 20,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(3600),
            resetDescription: nil)
        let burn = SessionEquivalentBurnEstimate(medianWeeklyPercentPerWindow: 10, sampleCount: 3)
        let extremeDate = Date(timeIntervalSinceReferenceDate: 1e30)

        #expect(SessionEquivalentForecast.make(
            sessionWindow: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: extremeDate,
                resetDescription: nil),
            weeklyWindow: RateWindow(
                usedPercent: 50,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(24 * 3600),
                resetDescription: nil),
            burnEstimate: burn,
            now: now,
            workDays: nil) == nil)
        #expect(SessionEquivalentForecast.make(
            sessionWindow: session,
            weeklyWindow: RateWindow(
                usedPercent: -1,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(24 * 3600),
                resetDescription: nil),
            burnEstimate: burn,
            now: now,
            workDays: nil) == nil)

        let fixture = Self.historyFixture(burns: [4, 6, 8])
        let encodedSession = try JSONEncoder().encode(fixture.histories[0])
        var sessionJSON = try #require(JSONSerialization.jsonObject(with: encodedSession) as? [String: Any])
        let entriesJSON = try #require(sessionJSON["entries"] as? [[String: Any]])
        sessionJSON["entries"] = Array(entriesJSON.reversed())
        let shuffledData = try JSONSerialization.data(withJSONObject: sessionJSON)
        let shuffledSession = try JSONDecoder().decode(PlanUtilizationSeriesHistory.self, from: shuffledData)
        #expect((shuffledSession.entries.first?.capturedAt ?? .distantPast)
            > (shuffledSession.entries.last?.capturedAt ?? .distantFuture))
        #expect(SessionEquivalentBurnEstimator.estimate(
            histories: [shuffledSession, fixture.histories[1]],
            currentSessionResetsAt: fixture.currentSessionReset,
            now: fixture.currentSessionReset.addingTimeInterval(-3600)) == nil)

        let huge = UsagePaceText.sessionEquivalentDetail(forecast: SessionEquivalentForecast(
            estimatedWindowsToExhaustWeekly: .greatestFiniteMagnitude,
            windowsUntilReset: 2,
            sampleCount: 7,
            weeklyResetsAt: Self.weeklyReset,
            weeklyUsedPercent: 1))
        #expect(huge.numberText.contains("full 5h windows"))
    }

    @Test
    func `does not replace unusable recent windows with older samples`() throws {
        let fixture = Self.historyFixture(burns: [20, 2, 4, 6, 8, 10, 12, 14])
        let lastReset = fixture.currentSessionReset.addingTimeInterval(-5 * 3600)
        let lastStart = lastReset.addingTimeInterval(-5 * 3600)
        let weekly = fixture.histories[1]
        let missingLatestBoundaries = PlanUtilizationSeriesHistory(
            name: weekly.name,
            windowMinutes: weekly.windowMinutes,
            entries: weekly.entries.filter { $0.capturedAt != lastStart && $0.capturedAt != lastReset })

        let estimate = try #require(SessionEquivalentBurnEstimator.estimate(
            histories: [fixture.histories[0], missingLatestBoundaries],
            currentSessionResetsAt: fixture.currentSessionReset,
            now: fixture.currentSessionReset.addingTimeInterval(-3600)))

        #expect(estimate.sampleCount == 5)
        #expect(estimate.medianWeeklyPercentPerWindow == 6)
    }

    @Test
    func `does not count a session whose reset is still in the future`() {
        let fixture = Self.historyFixture(burns: [5, 5])
        let now = fixture.currentSessionReset.addingTimeInterval(-3600)
        let futureReset = now.addingTimeInterval(30 * 60)
        let futureStart = futureReset.addingTimeInterval(-5 * 3600)
        let session = fixture.histories[0]
        let weekly = fixture.histories[1]
        let sessionEntries = (session.entries + [
            planEntry(at: futureStart.addingTimeInterval(3600), usedPercent: 80, resetsAt: futureReset),
        ]).sorted { $0.capturedAt < $1.capturedAt }
        let weeklyEntries = (weekly.entries + [
            planEntry(at: futureStart, usedPercent: 10, resetsAt: weekly.entries[0].resetsAt),
            planEntry(at: futureReset, usedPercent: 15, resetsAt: weekly.entries[0].resetsAt),
        ]).sorted { $0.capturedAt < $1.capturedAt }

        #expect(SessionEquivalentBurnEstimator.estimate(
            histories: [
                planSeries(name: .session, windowMinutes: 300, entries: sessionEntries),
                planSeries(name: .weekly, windowMinutes: 10080, entries: weeklyEntries),
            ],
            currentSessionResetsAt: fixture.currentSessionReset,
            now: now) == nil)
    }

    @Test
    func `provider metric shows estimate only on its matching weekly window`() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let weeklyReset = now.addingTimeInterval(2 * 24 * 3600)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 60,
                windowMinutes: 10080,
                resetsAt: weeklyReset,
                resetDescription: nil),
            updatedAt: now)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let forecast = SessionEquivalentForecast(
            estimatedWindowsToExhaustWeekly: 4,
            windowsUntilReset: 9,
            sampleCount: 7,
            weeklyResetsAt: weeklyReset,
            weeklyUsedPercent: 60)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            sessionEquivalentForecast: forecast,
            now: now))

        let sessionMetric = try #require(model.metrics.first { $0.id == "primary" })
        let weeklyMetric = try #require(model.metrics.first { $0.id == "secondary" })
        #expect(sessionMetric.sessionEquivalentDetail == nil)
        #expect(weeklyMetric.sessionEquivalentDetail?.verdictText == "Weekly can run out ≈5 windows early")
    }

    @MainActor
    @Test
    func `Claude scoped weekly window cannot use all model history`() throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let fixture = Self.historyFixture(burns: [4, 8, 6])
        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(unscoped: fixture.histories)
        let now = fixture.currentSessionReset.addingTimeInterval(-3600)
        let session = RateWindow(
            usedPercent: 20,
            windowMinutes: 300,
            resetsAt: fixture.currentSessionReset,
            resetDescription: nil)
        let scopedOnly = UsageSnapshot(
            primary: session,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "claude-weekly-scoped-fable",
                    title: "Fable weekly",
                    window: RateWindow(
                        usedPercent: 60,
                        windowMinutes: 10080,
                        resetsAt: now.addingTimeInterval(2 * 24 * 3600),
                        resetDescription: nil)),
            ],
            updatedAt: now)

        #expect(store.sessionEquivalentWindows(provider: .claude, snapshot: scopedOnly) == nil)

        let allModelsWeekly = RateWindow(
            usedPercent: 40,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(2 * 24 * 3600),
            resetDescription: nil)
        let complete = UsageSnapshot(
            primary: session,
            secondary: allModelsWeekly,
            extraRateWindows: scopedOnly.extraRateWindows,
            updatedAt: now)
        let resolved = try #require(store.sessionEquivalentWindows(provider: .claude, snapshot: complete))
        #expect(resolved.weekly == allModelsWeekly)
        #expect(resolved.weeklyWindowID == nil)
    }

    @Test
    func `named provider metric requires the selected weekly window identity`() {
        let weekly = RateWindow(
            usedPercent: 60,
            windowMinutes: 10080,
            resetsAt: Self.weeklyReset,
            resetDescription: nil)
        let forecast = SessionEquivalentForecast(
            estimatedWindowsToExhaustWeekly: 4,
            windowsUntilReset: 9,
            sampleCount: 7,
            weeklyResetsAt: Self.weeklyReset,
            weeklyUsedPercent: 60,
            weeklyWindowID: "antigravity-quota-summary-gemini-weekly")

        #expect(forecast.applies(
            to: weekly,
            windowID: "antigravity-quota-summary-gemini-weekly"))
        #expect(!forecast.applies(
            to: weekly,
            windowID: "antigravity-quota-summary-3p-weekly"))
    }

    @MainActor
    @Test
    func `usage store memoizes the history scan until revision changes`() {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let fixture = Self.historyFixture(burns: [4, 8, 6, 10])
        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(unscoped: fixture.histories)
        store.planUtilizationHistoryRevision = 1
        let now = fixture.currentSessionReset.addingTimeInterval(-3600)
        let session = RateWindow(
            usedPercent: 20,
            windowMinutes: 300,
            resetsAt: fixture.currentSessionReset,
            resetDescription: nil)
        let weekly = RateWindow(
            usedPercent: 60,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(2 * 24 * 3600),
            resetDescription: nil)

        #expect(store.sessionEquivalentForecast(
            provider: .claude,
            sessionWindow: session,
            weeklyWindow: weekly,
            now: now) != nil)
        #expect(store.sessionEquivalentForecast(
            provider: .claude,
            sessionWindow: session,
            weeklyWindow: weekly,
            now: now) != nil)
        #expect(store._sessionEquivalentHistoryScanCountForTesting == 1)

        store.planUtilizationHistoryRevision = 2
        #expect(store.sessionEquivalentForecast(
            provider: .claude,
            sessionWindow: session,
            weeklyWindow: weekly,
            now: now) != nil)
        #expect(store._sessionEquivalentHistoryScanCountForTesting == 2)
    }

    @MainActor
    @Test
    func `antigravity records session and weekly history without generic history opt in`() async {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-session",
                    title: "Gemini session",
                    window: RateWindow(
                        usedPercent: 20,
                        windowMinutes: 300,
                        resetsAt: now.addingTimeInterval(3600),
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini weekly",
                    window: RateWindow(
                        usedPercent: 40,
                        windowMinutes: 10080,
                        resetsAt: now.addingTimeInterval(3 * 24 * 3600),
                        resetDescription: nil)),
            ],
            updatedAt: now)

        #expect(store.settings.historicalTrackingEnabled == false)
        await store.recordPlanUtilizationHistorySample(provider: .antigravity, snapshot: snapshot, now: now)

        let histories = store.planUtilizationHistory(for: .antigravity)
        #expect(findSeries(histories, name: .session, windowMinutes: 300)?.entries.last?.usedPercent == 20)
        #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.last?.usedPercent == 40)
    }

    @MainActor
    @Test
    func `antigravity forecast keeps a stable Gemini quota family`() {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let before = Self.antigravitySnapshot(
            now: now,
            geminiSession: 20,
            geminiWeekly: 60,
            thirdPartySession: 30,
            thirdPartyWeekly: 50)
        let after = Self.antigravitySnapshot(
            now: now.addingTimeInterval(3600),
            geminiSession: 25,
            geminiWeekly: 61,
            thirdPartySession: 35,
            thirdPartyWeekly: 70)

        #expect(store.sessionEquivalentWindows(provider: .antigravity, snapshot: before)?.weekly.usedPercent == 60)
        #expect(store.sessionEquivalentWindows(provider: .antigravity, snapshot: after)?.weekly.usedPercent == 61)
        #expect(store.sessionEquivalentWindows(provider: .antigravity, snapshot: after)?.weeklyWindowID
            == "antigravity-quota-summary-gemini-weekly")
        #expect(store.sessionEquivalentWindows(
            provider: .antigravity,
            snapshot: Self.antigravitySnapshot(
                now: now,
                geminiSession: 20,
                geminiWeekly: 60,
                thirdPartySession: 30,
                thirdPartyWeekly: 50,
                geminiFamily: "gemini-pro")) == nil)
    }
}

extension SessionEquivalentForecastTests {
    @MainActor
    @Test
    func `generic named weekly window preserves its rendering identity`() throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "zai-named-session",
                    title: "Session",
                    window: RateWindow(
                        usedPercent: 20,
                        windowMinutes: 300,
                        resetsAt: now.addingTimeInterval(3600),
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "zai-named-weekly",
                    title: "Weekly",
                    window: RateWindow(
                        usedPercent: 40,
                        windowMinutes: 10080,
                        resetsAt: now.addingTimeInterval(3 * 24 * 3600),
                        resetDescription: nil)),
            ],
            updatedAt: now)

        let windows = try #require(store.sessionEquivalentWindows(provider: .zai, snapshot: snapshot))
        #expect(windows.weeklyWindowID == "zai-named-weekly")
    }

    @MainActor
    @Test
    func `generic named windows require the same quota family`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.historicalTrackingEnabled = true
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "family-a-session",
                    title: "A session",
                    window: RateWindow(
                        usedPercent: 20,
                        windowMinutes: 300,
                        resetsAt: now.addingTimeInterval(3600),
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "family-b-weekly",
                    title: "B weekly",
                    window: RateWindow(
                        usedPercent: 40,
                        windowMinutes: 10080,
                        resetsAt: now.addingTimeInterval(3 * 24 * 3600),
                        resetDescription: nil)),
            ],
            updatedAt: now)

        #expect(store.sessionEquivalentWindows(provider: .zai, snapshot: snapshot) == nil)
        await store.recordPlanUtilizationHistorySample(provider: .zai, snapshot: snapshot, now: now)
        let sessionWindow = try #require(snapshot.extraRateWindows?.first)
        let changedWeekly = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                sessionWindow,
                NamedRateWindow(
                    id: "family-c-weekly",
                    title: "C weekly",
                    window: RateWindow(
                        usedPercent: 50,
                        windowMinutes: 10080,
                        resetsAt: now.addingTimeInterval(3 * 24 * 3600),
                        resetDescription: nil)),
            ],
            updatedAt: now.addingTimeInterval(3600))
        await store.recordPlanUtilizationHistorySample(
            provider: .zai,
            snapshot: changedWeekly,
            now: changedWeekly.updatedAt)

        let histories = store.planUtilizationHistory(for: .zai)
        #expect(findSeries(histories, name: .session, windowMinutes: 300) == nil)
        #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.map(\.usedPercent) == [40])
    }

    @MainActor
    @Test
    func `first complete generic pair clears unidentified session history`() async {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.historicalTrackingEnabled = true
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let incomplete = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            updatedAt: now)
        await store.recordPlanUtilizationHistorySample(provider: .zai, snapshot: incomplete, now: now)

        let complete = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(
                usedPercent: 40,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(3 * 24 * 3600),
                resetDescription: nil),
            tertiary: RateWindow(
                usedPercent: 30,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(2 * 3600),
                resetDescription: nil),
            updatedAt: now.addingTimeInterval(3600))
        await store.recordPlanUtilizationHistorySample(provider: .zai, snapshot: complete, now: complete.updatedAt)

        let histories = store.planUtilizationHistory(for: .zai)
        #expect(findSeries(histories, name: .session, windowMinutes: 300)?.entries.map(\.usedPercent) == [30])
        #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.map(\.usedPercent) == [40])
    }

    @Test
    func `generic pair identity parser rejects overflowing component lengths`() {
        #expect(UsageStore.sessionEquivalentPairComponents(from: "\(Int.max)#x1#y") == nil)
    }

    @MainActor
    @Test
    func `generic identity migration preserves existing weekly history`() async {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.historicalTrackingEnabled = true
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        store.planUtilizationHistory[.zai] = PlanUtilizationHistoryBuckets(unscoped: [
            planSeries(
                name: .weekly,
                windowMinutes: 10080,
                entries: [
                    planEntry(at: now.addingTimeInterval(-7200), usedPercent: 30),
                    planEntry(at: now.addingTimeInterval(-3600), usedPercent: 35),
                ]),
        ])
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 40,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(3 * 24 * 3600),
                resetDescription: nil),
            updatedAt: now)

        await store.recordPlanUtilizationHistorySample(provider: .zai, snapshot: snapshot, now: now)

        let histories = store.planUtilizationHistory(for: .zai)
        #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.map(\.usedPercent)
            == [30, 35, 40])
        #expect(findSeries(histories, name: .session, windowMinutes: 300)?.entries.map(\.usedPercent) == [20])
        #expect(store.sessionEquivalentHistoryIdentityMatches(
            provider: .zai,
            accountKey: nil,
            historyIdentity: store.sessionEquivalentWindows(provider: .zai, snapshot: snapshot)?.historyIdentity))
    }

    @MainActor
    @Test
    func `generic history preserves session when weekly window identity changes`() async {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.historicalTrackingEnabled = true
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        func snapshot(weeklySlot: Int, sessionUsed: Double, weeklyUsed: Double, at date: Date) -> UsageSnapshot {
            let weekly = RateWindow(
                usedPercent: weeklyUsed,
                windowMinutes: 10080,
                resetsAt: date.addingTimeInterval(3 * 24 * 3600),
                resetDescription: nil)
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: sessionUsed,
                    windowMinutes: 300,
                    resetsAt: date.addingTimeInterval(3600),
                    resetDescription: nil),
                secondary: weeklySlot == 2 ? weekly : nil,
                tertiary: weeklySlot == 3 ? weekly : nil,
                updatedAt: date)
        }

        let first = snapshot(weeklySlot: 2, sessionUsed: 20, weeklyUsed: 40, at: now)
        let second = snapshot(
            weeklySlot: 3,
            sessionUsed: 30,
            weeklyUsed: 50,
            at: now.addingTimeInterval(3600))
        #expect(!store.sessionEquivalentHistoryIdentityMatches(
            provider: .zai,
            accountKey: nil,
            historyIdentity: store.sessionEquivalentWindows(provider: .zai, snapshot: first)?.historyIdentity))

        await store.recordPlanUtilizationHistorySample(provider: .zai, snapshot: first, now: first.updatedAt)
        #expect(store.sessionEquivalentHistoryIdentityMatches(
            provider: .zai,
            accountKey: nil,
            historyIdentity: store.sessionEquivalentWindows(provider: .zai, snapshot: first)?.historyIdentity))
        await store.recordPlanUtilizationHistorySample(provider: .zai, snapshot: second, now: second.updatedAt)

        let histories = store.planUtilizationHistory(for: .zai)
        #expect(findSeries(histories, name: .session, windowMinutes: 300)?.entries.map(\.usedPercent) == [20, 30])
        #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.map(\.usedPercent) == [50])
        #expect(store.sessionEquivalentHistoryIdentityMatches(
            provider: .zai,
            accountKey: nil,
            historyIdentity: store.sessionEquivalentWindows(provider: .zai, snapshot: second)?.historyIdentity))
    }

    @MainActor
    @Test
    func `generic history migration rejects a different legacy pair identity`() async {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.historicalTrackingEnabled = true
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        store.planUtilizationHistory[.zai] = PlanUtilizationHistoryBuckets(unscoped: [
            planSeries(
                name: .session,
                windowMinutes: 300,
                entries: [planEntry(at: now.addingTimeInterval(-3600), usedPercent: 10)]),
            planSeries(
                name: .weekly,
                windowMinutes: 10080,
                entries: [planEntry(at: now.addingTimeInterval(-3600), usedPercent: 30)]),
        ])
        store.settings.userDefaults.set(
            ["zai|\(UsageStore.planUtilizationUnscopedPreferredKey)": "legacy-pair"],
            forKey: UsageStore.legacySessionEquivalentHistoryIdentityDefaultsKey)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 40,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(3 * 24 * 3600),
                resetDescription: nil),
            updatedAt: now)

        await store.recordPlanUtilizationHistorySample(provider: .zai, snapshot: snapshot, now: now)

        let histories = store.planUtilizationHistory(for: .zai)
        #expect(findSeries(histories, name: .session, windowMinutes: 300)?.entries.map(\.usedPercent) == [20])
        #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.map(\.usedPercent) == [40])
    }

    @MainActor
    @Test
    func `generic legacy identity protects history during an incomplete first refresh`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.historicalTrackingEnabled = true
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let complete = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 40,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(3 * 24 * 3600),
                resetDescription: nil),
            updatedAt: now)
        let identity = try #require(store.sessionEquivalentWindows(
            provider: .zai,
            snapshot: complete)?.historyIdentity)
        store.planUtilizationHistory[.zai] = PlanUtilizationHistoryBuckets(unscoped: [
            planSeries(
                name: .session,
                windowMinutes: 300,
                entries: [planEntry(at: now.addingTimeInterval(-3600), usedPercent: 10)]),
            planSeries(
                name: .weekly,
                windowMinutes: 10080,
                entries: [planEntry(at: now.addingTimeInterval(-3600), usedPercent: 30)]),
        ])
        store.settings.userDefaults.set(
            ["zai|\(UsageStore.planUtilizationUnscopedPreferredKey)": identity],
            forKey: UsageStore.legacySessionEquivalentHistoryIdentityDefaultsKey)
        #expect(store.sessionEquivalentHistoryIdentityMatches(
            provider: .zai,
            accountKey: nil,
            historyIdentity: identity))
        let incomplete = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 50,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(2 * 3600),
                resetDescription: nil),
            secondary: nil,
            updatedAt: now.addingTimeInterval(3600))

        await store.recordPlanUtilizationHistorySample(
            provider: .zai,
            snapshot: incomplete,
            now: incomplete.updatedAt)

        let histories = store.planUtilizationHistory(for: .zai)
        #expect(findSeries(histories, name: .session, windowMinutes: 300)?.entries.map(\.usedPercent) == [10])
        #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.map(\.usedPercent) == [30])
        #expect(store.planUtilizationHistory[.zai]?
            .sessionEquivalentWindowPairIdentity(for: nil) == identity)
    }

    @MainActor
    @Test
    func `generic history preserves weekly when session window identity changes`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.historicalTrackingEnabled = true
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        func snapshot(sessionSlot: Int, sessionUsed: Double, at date: Date) -> UsageSnapshot {
            let session = RateWindow(
                usedPercent: sessionUsed,
                windowMinutes: 300,
                resetsAt: date.addingTimeInterval(3600),
                resetDescription: nil)
            return UsageSnapshot(
                primary: sessionSlot == 1 ? session : nil,
                secondary: RateWindow(
                    usedPercent: 40,
                    windowMinutes: 10080,
                    resetsAt: date.addingTimeInterval(3 * 24 * 3600),
                    resetDescription: nil),
                tertiary: sessionSlot == 3 ? session : nil,
                updatedAt: date)
        }

        let first = snapshot(sessionSlot: 1, sessionUsed: 20, at: now)
        let second = snapshot(
            sessionSlot: 3,
            sessionUsed: 30,
            at: now.addingTimeInterval(3600))
        await store.recordPlanUtilizationHistorySample(provider: .zai, snapshot: first, now: first.updatedAt)
        await store.recordPlanUtilizationHistorySample(provider: .zai, snapshot: second, now: second.updatedAt)

        let histories = store.planUtilizationHistory(for: .zai)
        #expect(findSeries(histories, name: .session, windowMinutes: 300)?.entries.map(\.usedPercent) == [30])
        #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.map(\.usedPercent) == [40, 40])
        let identity = try #require(store.sessionEquivalentWindows(provider: .zai, snapshot: second)?.historyIdentity)
        #expect(store.sessionEquivalentHistoryIdentityMatches(
            provider: .zai,
            accountKey: nil,
            historyIdentity: identity))
    }

    @MainActor
    @Test
    func `generic forecast rejects ambiguous session lanes while weekly history continues`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.historicalTrackingEnabled = true
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let session = RateWindow(
            usedPercent: 20,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(3600),
            resetDescription: nil)
        let snapshot = UsageSnapshot(
            primary: session,
            secondary: RateWindow(
                usedPercent: 40,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(3 * 24 * 3600),
                resetDescription: nil),
            tertiary: session,
            updatedAt: now)

        #expect(store.sessionEquivalentWindows(provider: .zai, snapshot: snapshot) == nil)

        func exactSnapshot(usedPercent: Double, at date: Date) -> UsageSnapshot {
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: 300,
                    resetsAt: date.addingTimeInterval(3600),
                    resetDescription: nil),
                secondary: snapshot.secondary,
                updatedAt: date)
        }

        let first = exactSnapshot(usedPercent: 10, at: now.addingTimeInterval(-3600))
        await store.recordPlanUtilizationHistorySample(provider: .zai, snapshot: first, now: first.updatedAt)
        let firstIdentity = try #require(store.sessionEquivalentWindows(
            provider: .zai,
            snapshot: first)?.historyIdentity)
        #expect(store.sessionEquivalentHistoryIdentityMatches(
            provider: .zai,
            accountKey: nil,
            historyIdentity: firstIdentity))
        store.settings.userDefaults.set(
            ["zai|\(UsageStore.planUtilizationUnscopedPreferredKey)": firstIdentity],
            forKey: UsageStore.legacySessionEquivalentHistoryIdentityDefaultsKey)

        await store.recordPlanUtilizationHistorySample(provider: .zai, snapshot: snapshot, now: now)
        #expect(store.sessionEquivalentHistoryIdentityMatches(
            provider: .zai,
            accountKey: nil,
            historyIdentity: firstIdentity))
        let ambiguousHistories = store.planUtilizationHistory(for: .zai)
        #expect(findSeries(ambiguousHistories, name: .session, windowMinutes: 300)?.entries.map(\.usedPercent) == [10])
        #expect(findSeries(ambiguousHistories, name: .weekly, windowMinutes: 10080)?.entries.map(\.usedPercent)
            == [40, 40])

        let incomplete = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 25,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(2 * 3600),
                resetDescription: nil),
            secondary: nil,
            updatedAt: now.addingTimeInterval(1800))
        await store.recordPlanUtilizationHistorySample(
            provider: .zai,
            snapshot: incomplete,
            now: incomplete.updatedAt)
        #expect(store.sessionEquivalentHistoryIdentityMatches(
            provider: .zai,
            accountKey: nil,
            historyIdentity: firstIdentity))

        let restored = exactSnapshot(usedPercent: 30, at: now.addingTimeInterval(3600))
        await store.recordPlanUtilizationHistorySample(provider: .zai, snapshot: restored, now: restored.updatedAt)
        let histories = store.planUtilizationHistory(for: .zai)
        #expect(findSeries(histories, name: .session, windowMinutes: 300)?.entries.map(\.usedPercent) == [10, 30])
        #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.map(\.usedPercent)
            == [40, 40, 40])
    }

    @MainActor
    @Test
    func `generic weekly ambiguity preserves both sides of prior pair history`() async {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.historicalTrackingEnabled = true
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let session = RateWindow(
            usedPercent: 20,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(3600),
            resetDescription: nil)

        func snapshot(weeklyValues: [Double], at date: Date) -> UsageSnapshot {
            UsageSnapshot(
                primary: session,
                secondary: weeklyValues.first.map {
                    RateWindow(
                        usedPercent: $0,
                        windowMinutes: 10080,
                        resetsAt: date.addingTimeInterval(3 * 24 * 3600),
                        resetDescription: nil)
                },
                tertiary: weeklyValues.dropFirst().first.map {
                    RateWindow(
                        usedPercent: $0,
                        windowMinutes: 10080,
                        resetsAt: date.addingTimeInterval(3 * 24 * 3600),
                        resetDescription: nil)
                },
                updatedAt: date)
        }

        let exact = snapshot(weeklyValues: [40], at: now)
        await store.recordPlanUtilizationHistorySample(provider: .zai, snapshot: exact, now: exact.updatedAt)

        let ambiguous = snapshot(weeklyValues: [45, 60], at: now.addingTimeInterval(3600))
        await store.recordPlanUtilizationHistorySample(
            provider: .zai,
            snapshot: ambiguous,
            now: ambiguous.updatedAt)

        let histories = store.planUtilizationHistory(for: .zai)
        #expect(findSeries(histories, name: .session, windowMinutes: 300)?.entries.map(\.usedPercent) == [20])
        #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.map(\.usedPercent) == [40])
    }

    @MainActor
    @Test
    func `generic account adoption moves pair identity with unscoped history`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.historicalTrackingEnabled = true
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 40,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(3 * 24 * 3600),
                resetDescription: nil),
            updatedAt: now)
        let identity = try #require(store.sessionEquivalentWindows(
            provider: .zai,
            snapshot: snapshot)?.historyIdentity)
        var buckets = PlanUtilizationHistoryBuckets(unscoped: [
            planSeries(
                name: .session,
                windowMinutes: 300,
                entries: [planEntry(at: now.addingTimeInterval(-3600), usedPercent: 10)]),
            planSeries(
                name: .weekly,
                windowMinutes: 10080,
                entries: [planEntry(at: now.addingTimeInterval(-3600), usedPercent: 30)]),
        ])
        buckets.setSessionEquivalentWindowPairIdentity(identity, for: nil)
        store.planUtilizationHistory[.zai] = buckets
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Zai test",
            token: "fixture",
            addedAt: 0,
            lastUsed: nil)
        let accountKey = try #require(UsageStore._planUtilizationTokenAccountKeyForTesting(
            provider: .zai,
            account: account))

        await store.recordPlanUtilizationHistorySample(
            provider: .zai,
            snapshot: snapshot,
            account: account,
            now: now)

        let migrated = try #require(store.planUtilizationHistory[.zai])
        #expect(migrated.unscoped.isEmpty)
        #expect(migrated.sessionEquivalentWindowPairIdentity(for: nil) == nil)
        #expect(migrated.sessionEquivalentWindowPairIdentity(for: accountKey) == identity)
        let histories = migrated.histories(for: accountKey)
        #expect(findSeries(histories, name: .session, windowMinutes: 300)?.entries.map(\.usedPercent) == [10, 20])
        #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.map(\.usedPercent) == [30, 40])
    }

    @MainActor
    @Test
    func `generic pair identity distinguishes delimiter bearing family names`() throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        func identity(sessionID: String, weeklyID: String) throws -> String {
            let snapshot = UsageSnapshot(
                primary: nil,
                secondary: nil,
                extraRateWindows: [
                    NamedRateWindow(
                        id: sessionID,
                        title: "Session",
                        window: RateWindow(
                            usedPercent: 20,
                            windowMinutes: 300,
                            resetsAt: now.addingTimeInterval(3600),
                            resetDescription: nil)),
                    NamedRateWindow(
                        id: weeklyID,
                        title: "Weekly",
                        window: RateWindow(
                            usedPercent: 40,
                            windowMinutes: 10080,
                            resetsAt: now.addingTimeInterval(3 * 24 * 3600),
                            resetDescription: nil)),
                ],
                updatedAt: now)
            return try #require(store.sessionEquivalentWindows(
                provider: .zai,
                snapshot: snapshot)?.historyIdentity)
        }

        let first = try identity(
            sessionID: "a|weekly:named:b-session",
            weeklyID: "a|weekly:named:b-weekly")
        let second = try identity(sessionID: "a-session", weeklyID: "a-weekly")
        #expect(first != second)
    }

    @MainActor
    @Test
    func `generic incomplete refresh preserves established pair history`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.historicalTrackingEnabled = true
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let session = RateWindow(
            usedPercent: 20,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(3600),
            resetDescription: nil)
        let complete = UsageSnapshot(
            primary: session,
            secondary: RateWindow(
                usedPercent: 40,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(3 * 24 * 3600),
                resetDescription: nil),
            updatedAt: now)
        let incomplete = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 30,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(2 * 3600),
                resetDescription: nil),
            secondary: nil,
            updatedAt: now.addingTimeInterval(3600))

        await store.recordPlanUtilizationHistorySample(provider: .zai, snapshot: complete, now: complete.updatedAt)
        let identity = try #require(store.sessionEquivalentWindows(
            provider: .zai,
            snapshot: complete)?.historyIdentity)
        await store.recordPlanUtilizationHistorySample(
            provider: .zai,
            snapshot: incomplete,
            now: incomplete.updatedAt)

        #expect(store.sessionEquivalentHistoryIdentityMatches(
            provider: .zai,
            accountKey: nil,
            historyIdentity: identity))
        let histories = store.planUtilizationHistory(for: .zai)
        #expect(findSeries(histories, name: .session, windowMinutes: 300)?.entries.map(\.usedPercent) == [20])
        #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.map(\.usedPercent) == [40])
    }
}

extension SessionEquivalentForecastTests {
    @MainActor
    @Test
    func `antigravity history skips refreshes without the pinned Gemini family`() async {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        store.planUtilizationHistory[.antigravity] = PlanUtilizationHistoryBuckets(unscoped: [
            planSeries(
                name: .weekly,
                windowMinutes: 10080,
                entries: [planEntry(at: now.addingTimeInterval(-3600), usedPercent: 99)]),
        ])
        let complete = Self.antigravitySnapshot(
            now: now,
            geminiSession: 20,
            geminiWeekly: 60,
            thirdPartySession: 30,
            thirdPartyWeekly: 50)
        let thirdPartyOnly = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: complete.extraRateWindows?.filter { $0.id.contains("3p") },
            updatedAt: now.addingTimeInterval(3600))

        await store.recordPlanUtilizationHistorySample(provider: .antigravity, snapshot: complete, now: now)
        await store.recordPlanUtilizationHistorySample(
            provider: .antigravity,
            snapshot: thirdPartyOnly,
            now: thirdPartyOnly.updatedAt)

        let histories = store.planUtilizationHistory(for: .antigravity)
        #expect(findSeries(histories, name: .session, windowMinutes: 300)?.entries.map(\.usedPercent) == [20])
        #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.map(\.usedPercent) == [60])
    }

    private static func antigravitySnapshot(
        now: Date,
        geminiSession: Double,
        geminiWeekly: Double,
        thirdPartySession: Double,
        thirdPartyWeekly: Double,
        geminiFamily: String = "gemini") -> UsageSnapshot
    {
        UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-\(geminiFamily)-5h",
                    title: "Gemini 5-hour",
                    window: RateWindow(
                        usedPercent: geminiSession,
                        windowMinutes: 300,
                        resetsAt: now.addingTimeInterval(3600),
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-\(geminiFamily)-weekly",
                    title: "Gemini weekly",
                    window: RateWindow(
                        usedPercent: geminiWeekly,
                        windowMinutes: 10080,
                        resetsAt: now.addingTimeInterval(3 * 24 * 3600),
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-5h",
                    title: "Third party 5-hour",
                    window: RateWindow(
                        usedPercent: thirdPartySession,
                        windowMinutes: 300,
                        resetsAt: now.addingTimeInterval(3600),
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Third party weekly",
                    window: RateWindow(
                        usedPercent: thirdPartyWeekly,
                        windowMinutes: 10080,
                        resetsAt: now.addingTimeInterval(3 * 24 * 3600),
                        resetDescription: nil)),
            ],
            updatedAt: now)
    }

    private static func historyFixture(burns: [Double])
        -> (histories: [PlanUtilizationSeriesHistory], currentSessionReset: Date)
    {
        self.historyFixture(samples: burns.map {
            (sessionUsedPercent: 100, weeklyBurnPercent: $0)
        })
    }

    private static func historyFixture(
        samples: [(sessionUsedPercent: Double, weeklyBurnPercent: Double)])
        -> (histories: [PlanUtilizationSeriesHistory], currentSessionReset: Date)
    {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let duration: TimeInterval = 5 * 3600
        let weeklyReset = start.addingTimeInterval(7 * 24 * 3600)
        var sessionEntries: [PlanUtilizationHistoryEntry] = []
        var weeklyEntries: [PlanUtilizationHistoryEntry] = []
        var weeklyUsed = 0.0

        for (index, sample) in samples.enumerated() {
            let windowStart = start.addingTimeInterval(Double(index) * duration)
            let reset = windowStart.addingTimeInterval(duration)
            sessionEntries.append(planEntry(
                at: windowStart.addingTimeInterval(30 * 60),
                usedPercent: min(20, sample.sessionUsedPercent),
                resetsAt: reset))
            sessionEntries.append(planEntry(
                at: reset.addingTimeInterval(-30 * 60),
                usedPercent: sample.sessionUsedPercent,
                resetsAt: reset))
            weeklyEntries.append(planEntry(at: windowStart, usedPercent: weeklyUsed, resetsAt: weeklyReset))
            weeklyUsed += sample.weeklyBurnPercent
            weeklyEntries.append(planEntry(at: reset, usedPercent: weeklyUsed, resetsAt: weeklyReset))
        }

        return (
            histories: [
                planSeries(name: .session, windowMinutes: 300, entries: sessionEntries),
                planSeries(name: .weekly, windowMinutes: 10080, entries: weeklyEntries),
            ],
            currentSessionReset: start.addingTimeInterval(Double(samples.count + 1) * duration))
    }

    private static func alignedPartialHistoryFixture()
        -> (histories: [PlanUtilizationSeriesHistory], currentSessionReset: Date)
    {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let duration: TimeInterval = 5 * 3600
        let weeklyReset = start.addingTimeInterval(7 * 24 * 3600)
        let fullAllowanceBurn = 10.0
        var sessionEntries: [PlanUtilizationHistoryEntry] = []
        var weeklyEntries: [PlanUtilizationHistoryEntry] = []
        var weeklyUsed = 0.0

        for (index, sessionUsedPercent) in [20.0, 40.0, 100.0].enumerated() {
            let windowStart = start.addingTimeInterval(Double(index) * duration)
            let reset = windowStart.addingTimeInterval(duration)
            let firstSessionUsedPercent = sessionUsedPercent / 4
            let firstCapturedAt = windowStart.addingTimeInterval(30 * 60)
            let lastCapturedAt = reset.addingTimeInterval(-30 * 60)
            let firstWeeklyUsedPercent = weeklyUsed + fullAllowanceBurn * firstSessionUsedPercent / 100
            let lastWeeklyUsedPercent = weeklyUsed + fullAllowanceBurn * sessionUsedPercent / 100

            sessionEntries.append(planEntry(
                at: firstCapturedAt,
                usedPercent: firstSessionUsedPercent,
                resetsAt: reset))
            weeklyEntries.append(planEntry(
                at: firstCapturedAt,
                usedPercent: firstWeeklyUsedPercent,
                resetsAt: weeklyReset))
            sessionEntries.append(planEntry(
                at: lastCapturedAt,
                usedPercent: sessionUsedPercent,
                resetsAt: reset))
            weeklyEntries.append(planEntry(
                at: lastCapturedAt,
                usedPercent: lastWeeklyUsedPercent,
                resetsAt: weeklyReset))
            weeklyUsed = lastWeeklyUsedPercent
        }

        let histories = UsageStore._updatedPlanUtilizationHistoriesForTesting(
            existingHistories: [],
            samples: [
                planSeries(name: .session, windowMinutes: 300, entries: sessionEntries),
                planSeries(name: .weekly, windowMinutes: 10080, entries: weeklyEntries),
            ]) ?? []
        return (
            histories: histories,
            currentSessionReset: start.addingTimeInterval(4 * duration))
    }

    private static func straddledBoundaryHistoryFixture()
        -> (histories: [PlanUtilizationSeriesHistory], currentSessionReset: Date)
    {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let duration: TimeInterval = 5 * 3600
        let stride: TimeInterval = 6 * 3600
        let weeklyReset = start.addingTimeInterval(7 * 24 * 3600)
        var sessionEntries: [PlanUtilizationHistoryEntry] = []
        var weeklyEntries: [PlanUtilizationHistoryEntry] = []
        var weeklyUsed = 0.0

        for index in 0..<3 {
            let windowStart = start.addingTimeInterval(Double(index) * stride)
            let reset = windowStart.addingTimeInterval(duration)
            sessionEntries.append(planEntry(
                at: windowStart.addingTimeInterval(30 * 60),
                usedPercent: 20,
                resetsAt: reset))
            sessionEntries.append(planEntry(
                at: reset.addingTimeInterval(-30 * 60),
                usedPercent: 100,
                resetsAt: reset))
            weeklyEntries.append(planEntry(
                at: windowStart.addingTimeInterval(-90),
                usedPercent: weeklyUsed,
                resetsAt: weeklyReset))
            weeklyEntries.append(planEntry(
                at: windowStart.addingTimeInterval(30),
                usedPercent: weeklyUsed,
                resetsAt: weeklyReset))
            weeklyUsed += 10
            weeklyEntries.append(planEntry(
                at: reset.addingTimeInterval(-90),
                usedPercent: weeklyUsed,
                resetsAt: weeklyReset))
            weeklyEntries.append(planEntry(
                at: reset.addingTimeInterval(30),
                usedPercent: weeklyUsed,
                resetsAt: weeklyReset))
        }

        return (
            histories: [
                planSeries(name: .session, windowMinutes: 300, entries: sessionEntries),
                planSeries(name: .weekly, windowMinutes: 10080, entries: weeklyEntries),
            ],
            currentSessionReset: start.addingTimeInterval(3 * stride + duration))
    }
}
