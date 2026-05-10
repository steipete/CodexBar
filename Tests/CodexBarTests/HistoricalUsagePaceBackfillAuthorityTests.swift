import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension HistoricalUsagePaceTests {
    @MainActor
    @Test
    func `backfill skips when dashboard authority is display only`() async throws {
        let store = try Self.makeUsageStoreForBackfillTests(
            suite: "HistoricalUsagePaceTests-backfill-display-only",
            historyFileURL: Self.makeTempURL())
        store._setCodexHistoricalDatasetForTesting(nil)

        let snapshotNow = Date(timeIntervalSince1970: 1_770_000_000)
        let dashboard = OpenAIDashboardSnapshot(
            signedInEmail: "shared@example.com",
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: Self.syntheticBreakdown(endingAt: snapshotNow, days: 35, dailyCredits: 10),
            creditsPurchaseURL: nil,
            primaryLimit: nil,
            secondaryLimit: RateWindow(
                usedPercent: 50,
                windowMinutes: 10080,
                resetsAt: snapshotNow.addingTimeInterval(2 * 24 * 60 * 60),
                resetDescription: nil),
            creditsRemaining: nil,
            accountPlan: nil,
            updatedAt: snapshotNow)

        store.backfillCodexHistoricalFromDashboardIfNeeded(
            dashboard,
            authorityDecision: CodexDashboardAuthorityDecision(
                disposition: .displayOnly,
                reason: .sameEmailAmbiguity(email: "shared@example.com"),
                allowedEffects: [],
                cleanup: Set(CodexDashboardCleanup.allCases)),
            attachedAccountEmail: "shared@example.com")

        try await Task.sleep(for: .milliseconds(250))
        #expect(store.codexHistoricalDataset == nil)
    }

    @MainActor
    @Test
    func `backfill skips when dashboard authority fail closes`() async throws {
        let store = try Self.makeUsageStoreForBackfillTests(
            suite: "HistoricalUsagePaceTests-backfill-fail-closed",
            historyFileURL: Self.makeTempURL())
        store._setCodexHistoricalDatasetForTesting(nil)

        let snapshotNow = Date(timeIntervalSince1970: 1_770_000_000)
        let dashboard = OpenAIDashboardSnapshot(
            signedInEmail: "wrong@example.com",
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: Self.syntheticBreakdown(endingAt: snapshotNow, days: 35, dailyCredits: 10),
            creditsPurchaseURL: nil,
            primaryLimit: nil,
            secondaryLimit: RateWindow(
                usedPercent: 50,
                windowMinutes: 10080,
                resetsAt: snapshotNow.addingTimeInterval(2 * 24 * 60 * 60),
                resetDescription: nil),
            creditsRemaining: nil,
            accountPlan: nil,
            updatedAt: snapshotNow)

        store.backfillCodexHistoricalFromDashboardIfNeeded(
            dashboard,
            authorityDecision: CodexDashboardAuthorityDecision(
                disposition: .failClosed,
                reason: .wrongEmail(expected: "expected@example.com", actual: "wrong@example.com"),
                allowedEffects: [],
                cleanup: Set(CodexDashboardCleanup.allCases)),
            attachedAccountEmail: "expected@example.com")

        try await Task.sleep(for: .milliseconds(250))
        #expect(store.codexHistoricalDataset == nil)
    }

    @MainActor
    @Test
    func `backfill uses dashboard secondary when available`() async throws {
        let store = try Self.makeUsageStoreForBackfillTests(
            suite: "HistoricalUsagePaceTests-backfill-dashboard-secondary",
            historyFileURL: Self.makeTempURL())
        store._setCodexHistoricalDatasetForTesting(nil)

        let snapshotNow = Date(timeIntervalSince1970: 1_770_000_000)
        let staleSnapshot = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(
                usedPercent: 5,
                windowMinutes: 10080,
                resetsAt: snapshotNow.addingTimeInterval(2 * 24 * 60 * 60),
                resetDescription: nil),
            tertiary: nil,
            providerCost: nil,
            updatedAt: snapshotNow.addingTimeInterval(-30 * 60),
            identity: nil)
        store._setSnapshotForTesting(staleSnapshot, provider: .codex)

        let dashboard = OpenAIDashboardSnapshot(
            signedInEmail: nil,
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: Self.syntheticBreakdown(endingAt: snapshotNow, days: 35, dailyCredits: 10),
            creditsPurchaseURL: nil,
            primaryLimit: nil,
            secondaryLimit: RateWindow(
                usedPercent: 50,
                windowMinutes: 10080,
                resetsAt: snapshotNow.addingTimeInterval(2 * 24 * 60 * 60),
                resetDescription: nil),
            creditsRemaining: nil,
            accountPlan: nil,
            updatedAt: snapshotNow)
        store.backfillCodexHistoricalFromDashboardIfNeeded(
            dashboard,
            authorityDecision: CodexDashboardAuthorityDecision(
                disposition: .attach,
                reason: .trustedEmailMatchNoCompetingOwner,
                allowedEffects: [.historicalBackfill],
                cleanup: []),
            attachedAccountEmail: "attached@example.com")

        for _ in 0..<40 {
            if (store.codexHistoricalDataset?.weeks.count ?? 0) >= 3 {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect((store.codexHistoricalDataset?.weeks.count ?? 0) >= 3)
    }

    @MainActor
    @Test
    func `backfill uses normalized dashboard weekly when only primary window is weekly`() async throws {
        let store = try Self.makeUsageStoreForBackfillTests(
            suite: "HistoricalUsagePaceTests-backfill-normalized-dashboard-weekly",
            historyFileURL: Self.makeTempURL())
        store._setCodexHistoricalDatasetForTesting(nil)

        let snapshotNow = Date(timeIntervalSince1970: 1_770_000_000)
        let seededSnapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 22,
                windowMinutes: 300,
                resetsAt: snapshotNow.addingTimeInterval(2 * 60 * 60),
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: snapshotNow,
            identity: nil)
        store._setSnapshotForTesting(seededSnapshot, provider: .codex)

        let dashboard = OpenAIDashboardSnapshot(
            signedInEmail: nil,
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: Self.syntheticBreakdown(endingAt: snapshotNow, days: 35, dailyCredits: 10),
            creditsPurchaseURL: nil,
            primaryLimit: RateWindow(
                usedPercent: 50,
                windowMinutes: 10080,
                resetsAt: snapshotNow.addingTimeInterval(2 * 24 * 60 * 60),
                resetDescription: nil),
            secondaryLimit: nil,
            creditsRemaining: nil,
            accountPlan: nil,
            updatedAt: snapshotNow)
        store.backfillCodexHistoricalFromDashboardIfNeeded(
            dashboard,
            authorityDecision: CodexDashboardAuthorityDecision(
                disposition: .attach,
                reason: .trustedEmailMatchNoCompetingOwner,
                allowedEffects: [.historicalBackfill],
                cleanup: []),
            attachedAccountEmail: "attached@example.com")

        for _ in 0..<40 {
            if (store.codexHistoricalDataset?.weeks.count ?? 0) >= 3 {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect((store.codexHistoricalDataset?.weeks.count ?? 0) >= 3)
    }

    @MainActor
    @Test
    func `backfill uses attached account email from authority instead of dashboard email`() async throws {
        let store = try Self.makeUsageStoreForBackfillTests(
            suite: "HistoricalUsagePaceTests-backfill-attached-email",
            historyFileURL: Self.makeTempURL())
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-historical-attached-email-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        store.settings._test_liveSystemCodexAccount = nil
        store.settings._test_codexReconciliationEnvironment = ["CODEX_HOME": isolatedHome.path]
        defer {
            store.settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: isolatedHome)
        }
        store._setCodexHistoricalDatasetForTesting(nil)

        let snapshotNow = Date(timeIntervalSince1970: 1_770_000_000)
        let dashboard = OpenAIDashboardSnapshot(
            signedInEmail: "dashboard@example.com",
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: Self.syntheticBreakdown(endingAt: snapshotNow, days: 35, dailyCredits: 10),
            creditsPurchaseURL: nil,
            primaryLimit: nil,
            secondaryLimit: RateWindow(
                usedPercent: 50,
                windowMinutes: 10080,
                resetsAt: snapshotNow.addingTimeInterval(2 * 24 * 60 * 60),
                resetDescription: nil),
            creditsRemaining: nil,
            accountPlan: nil,
            updatedAt: snapshotNow)

        store.backfillCodexHistoricalFromDashboardIfNeeded(
            dashboard,
            authorityDecision: CodexDashboardAuthorityDecision(
                disposition: .attach,
                reason: .trustedEmailMatchNoCompetingOwner,
                allowedEffects: [.historicalBackfill],
                cleanup: []),
            attachedAccountEmail: "attached@example.com")

        for _ in 0..<40 {
            if store.codexHistoricalDatasetAccountKey != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(
            store.codexHistoricalDatasetAccountKey ==
                CodexHistoryOwnership.canonicalEmailHashKey(for: "attached@example.com"))
        #expect(
            store.codexHistoricalDatasetAccountKey !=
                CodexHistoryOwnership.canonicalEmailHashKey(for: "dashboard@example.com"))
    }

    @Test
    func `will last decision uses smoothed probability when risk hidden`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let windowMinutes = 10080
        let duration = TimeInterval(windowMinutes) * 60
        let currentResetsAt = now.addingTimeInterval(duration / 2)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: windowMinutes,
            resetsAt: currentResetsAt,
            resetDescription: nil)

        let weeks = (0..<4).map { index in
            HistoricalWeekProfile(
                resetsAt: currentResetsAt.addingTimeInterval(-duration * Double(index + 1)),
                windowMinutes: windowMinutes,
                curve: Self.linearCurve(end: 100))
        }
        let pace = try #require(CodexHistoricalPaceEvaluator.evaluate(
            window: window,
            now: now,
            dataset: CodexHistoricalDataset(weeks: weeks)))
        #expect(pace.runOutProbability == nil)

        let totalWeight = weeks.enumerated().reduce(0.0) { partial, element in
            let ageWeeks = currentResetsAt.timeIntervalSince(element.element.resetsAt) / duration
            return partial + exp(-ageWeeks / 3.0)
        }
        let smoothedProbability = (totalWeight + 0.5) / (totalWeight + 1.0)
        #expect(pace.willLastToReset == (smoothedProbability < 0.5))
    }

    @MainActor
    @Test
    func `usage store falls back to linear when history disabled or insufficient`() throws {
        let suite = "HistoricalUsagePaceTests-usage-store"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.historicalTrackingEnabled = true

        let planHistoryStore = testPlanUtilizationHistoryStore(
            suiteName: "HistoricalUsagePaceTests-\(UUID().uuidString)")
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            historicalUsageHistoryStore: HistoricalUsageHistoryStore(fileURL: Self.makeTempURL()),
            planUtilizationHistoryStore: planHistoryStore)

        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60),
            resetDescription: nil)

        let twoWeeksDataset = CodexHistoricalDataset(weeks: [
            HistoricalWeekProfile(
                resetsAt: now.addingTimeInterval(-7 * 24 * 60 * 60),
                windowMinutes: 10080,
                curve: Self.linearCurve(end: 100)),
            HistoricalWeekProfile(
                resetsAt: now.addingTimeInterval(-14 * 24 * 60 * 60),
                windowMinutes: 10080,
                curve: Self.linearCurve(end: 100)),
        ])
        store._setCodexHistoricalDatasetForTesting(twoWeeksDataset)

        let computed = store.weeklyPace(provider: .codex, window: window, now: now)
        let linear = UsagePace.weekly(window: window, now: now, defaultWindowMinutes: 10080)
        #expect(computed != nil)
        #expect(abs((computed?.deltaPercent ?? 0) - (linear?.deltaPercent ?? 0)) < 0.001)
    }

    @MainActor
    @Test
    func `usage store computes linear pace for providers with quota windows`() throws {
        let suite = "HistoricalUsagePaceTests-generic-provider-\(UUID().uuidString)"
        let store = try Self.makeUsageStoreForBackfillTests(
            suite: suite,
            historyFileURL: Self.makeTempURL())

        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 40,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60),
            resetDescription: nil)

        let pace = store.weeklyPace(provider: .zai, window: window, now: now)

        #expect(pace != nil)
        #expect(abs((pace?.deltaPercent ?? 0) - (40 - (3.0 / 7.0 * 100.0))) < 0.001)
    }

    @MainActor
    @Test
    func `usage store returns nil pace when generic window lacks explicit duration`() throws {
        let suite = "HistoricalUsagePaceTests-no-window-minutes-\(UUID().uuidString)"
        let store = try Self.makeUsageStoreForBackfillTests(
            suite: suite,
            historyFileURL: Self.makeTempURL())

        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 40,
            windowMinutes: nil,
            resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60),
            resetDescription: nil)

        let pace = store.weeklyPace(provider: .factory, window: window, now: now)

        #expect(pace == nil)
    }
}
