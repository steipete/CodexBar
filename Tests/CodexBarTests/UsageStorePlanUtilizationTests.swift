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

    @Test
    func chartEmptyStateShowsRefreshingWhileLoading() throws {
        let text = try #require(
            PlanUtilizationHistoryChartMenuView._emptyStateTextForTesting(
                periodRawValue: "daily",
                isRefreshing: true))

        #expect(text == "Refreshing...")
    }

    @Test
    func chartEmptyStateShowsPeriodSpecificMessageWhenNotRefreshing() throws {
        let text = try #require(
            PlanUtilizationHistoryChartMenuView._emptyStateTextForTesting(
                periodRawValue: "weekly",
                isRefreshing: false))

        #expect(text == "No weekly utilization data yet.")
    }

    @MainActor
    @Test
    func planHistorySelectsCurrentAccountBucket() throws {
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

        let aliceSample = PlanUtilizationHistorySample(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            dailyUsedPercent: 10,
            weeklyUsedPercent: 20,
            monthlyUsedPercent: 30)
        let bobSample = PlanUtilizationHistorySample(
            capturedAt: Date(timeIntervalSince1970: 1_700_086_400),
            dailyUsedPercent: 40,
            weeklyUsedPercent: 50,
            monthlyUsedPercent: 60)

        store.planUtilizationHistory[.codex] = PlanUtilizationHistoryBuckets(
            unscoped: [
                PlanUtilizationHistorySample(
                    capturedAt: Date(timeIntervalSince1970: 1_699_913_600),
                    dailyUsedPercent: 90,
                    weeklyUsedPercent: 90,
                    monthlyUsedPercent: 90),
            ],
            accounts: [
                aliceKey: [aliceSample],
                bobKey: [bobSample],
            ])

        store._setSnapshotForTesting(aliceSnapshot, provider: .codex)
        #expect(store.planUtilizationHistory(for: .codex) == [aliceSample])

        store._setSnapshotForTesting(bobSnapshot, provider: .codex)
        #expect(store.planUtilizationHistory(for: .codex) == [bobSample])
    }

    @MainActor
    @Test
    func planHistorySelectsConfiguredTokenAccountBucket() throws {
        let store = Self.makeStore()
        store.settings.addTokenAccount(provider: .claude, label: "Alice", token: "alice-token")
        store.settings.addTokenAccount(provider: .claude, label: "Bob", token: "bob-token")

        let accounts = store.settings.tokenAccounts(for: .claude)
        let alice = try #require(accounts.first)
        let bob = try #require(accounts.last)
        let aliceKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(
                provider: .claude,
                account: alice))
        let bobKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(
                provider: .claude,
                account: bob))

        let aliceSample = PlanUtilizationHistorySample(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            dailyUsedPercent: 15,
            weeklyUsedPercent: 25,
            monthlyUsedPercent: 35)
        let bobSample = PlanUtilizationHistorySample(
            capturedAt: Date(timeIntervalSince1970: 1_700_086_400),
            dailyUsedPercent: 45,
            weeklyUsedPercent: 55,
            monthlyUsedPercent: 65)

        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(
            accounts: [
                aliceKey: [aliceSample],
                bobKey: [bobSample],
            ])

        store.settings.setActiveTokenAccountIndex(0, for: .claude)
        #expect(store.planUtilizationHistory(for: .claude) == [aliceSample])

        store.settings.setActiveTokenAccountIndex(1, for: .claude)
        #expect(store.planUtilizationHistory(for: .claude) == [bobSample])
    }

    @MainActor
    @Test
    func recordPlanHistoryWithoutExplicitAccountUsesSelectedTokenAccountBucket() async throws {
        let store = Self.makeStore()
        store.settings.addTokenAccount(provider: .claude, label: "Alice", token: "alice-token")
        store.settings.addTokenAccount(provider: .claude, label: "Bob", token: "bob-token")
        store.settings.setActiveTokenAccountIndex(1, for: .claude)

        let aliceSnapshot = Self.makeSnapshot(provider: .claude, email: "alice@example.com")
        let selectedTokenKey = try #require(
            store.settings.selectedTokenAccount(for: .claude).flatMap {
                UsageStore._planUtilizationTokenAccountKeyForTesting(provider: .claude, account: $0)
            })

        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: aliceSnapshot,
            now: Date(timeIntervalSince1970: 1_700_000_000))

        let buckets = try #require(store.planUtilizationHistory[.claude])
        #expect(buckets.accounts[selectedTokenKey]?.count == 1)
    }

    @MainActor
    @Test
    func applySelectedOutcomeRecordsPlanHistoryForSelectedTokenAccount() async throws {
        let store = Self.makeStore()
        store.settings.addTokenAccount(provider: .claude, label: "Alice", token: "alice-token")
        store.settings.addTokenAccount(provider: .claude, label: "Bob", token: "bob-token")
        store.settings.setActiveTokenAccountIndex(1, for: .claude)

        let selectedAccount = try #require(store.settings.selectedTokenAccount(for: .claude))
        let selectedTokenKey = try #require(
            UsageStore._planUtilizationTokenAccountKeyForTesting(provider: .claude, account: selectedAccount))
        let snapshot = Self.makeSnapshot(provider: .claude, email: "alice@example.com")
        let outcome = ProviderFetchOutcome(
            result: .success(
                ProviderFetchResult(
                    usage: snapshot,
                    credits: nil,
                    dashboard: nil,
                    sourceLabel: "test",
                    strategyID: "test",
                    strategyKind: .web)),
            attempts: [])

        await store.applySelectedOutcome(
            outcome,
            provider: .claude,
            account: selectedAccount,
            fallbackSnapshot: snapshot)

        let buckets = try #require(store.planUtilizationHistory[.claude])
        #expect(buckets.accounts[selectedTokenKey]?.count == 1)
    }

    @MainActor
    @Test
    func codexPlanHistoryFallsBackToUnscopedBucketWhenIdentityIsUnavailable() {
        let store = Self.makeStore()
        let sample = PlanUtilizationHistorySample(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            dailyUsedPercent: 20,
            weeklyUsedPercent: 30,
            monthlyUsedPercent: 40)

        store.planUtilizationHistory[.codex] = PlanUtilizationHistoryBuckets(unscoped: [sample])
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: nil,
                secondary: nil,
                updatedAt: Date()),
            provider: .codex)

        #expect(store.planUtilizationHistory(for: .codex) == [sample])
    }

    @MainActor
    @Test
    func claudePlanHistoryReturnsEmptyWhenIdentityIsUnavailable() {
        let store = Self.makeStore()
        let sample = PlanUtilizationHistorySample(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            dailyUsedPercent: 20,
            weeklyUsedPercent: 30,
            monthlyUsedPercent: nil)

        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(
            unscoped: [sample],
            accounts: ["claude-account-key": [sample]])

        #expect(store.planUtilizationHistory(for: .claude).isEmpty)
    }

    @MainActor
    @Test
    func planHistoryDoesNotReadLegacyIdentityBucketForTokenAccounts() throws {
        let store = Self.makeStore()
        store.settings.addTokenAccount(provider: .claude, label: "Alice", token: "alice-token")

        let snapshot = Self.makeSnapshot(provider: .claude, email: "alice@example.com")
        let legacyKey = try #require(
            UsageStore._planUtilizationAccountKeyForTesting(
                provider: .claude,
                snapshot: snapshot))
        let legacySample = PlanUtilizationHistorySample(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            dailyUsedPercent: 10,
            weeklyUsedPercent: 20,
            monthlyUsedPercent: nil)

        store.planUtilizationHistory[.claude] = PlanUtilizationHistoryBuckets(
            accounts: [legacyKey: [legacySample]])
        store._setSnapshotForTesting(snapshot, provider: .claude)

        #expect(store.planUtilizationHistory(for: .claude).isEmpty)
    }

    @MainActor
    @Test
    func recordPlanHistoryWithoutIdentitySkipsClaudeWrite() async {
        let store = Self.makeStore()
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 11, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 21, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_700_003_600))
        let existingHistory = store.planUtilizationHistory[.claude]

        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_700_003_600))

        #expect(store.planUtilizationHistory[.claude] == existingHistory)
    }

    @Test
    func storeLoadsLegacyProviderHistoryIntoUnscopedBucket() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileManager = PlanHistoryFileManager(applicationSupportURL: root)
        let url = root
            .appendingPathComponent("com.steipete.codexbar", isDirectory: true)
            .appendingPathComponent("plan-utilization-history.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let sample = PlanUtilizationHistorySample(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            dailyUsedPercent: 10,
            weeklyUsedPercent: 20,
            monthlyUsedPercent: 30)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(LegacyPlanUtilizationHistoryFileFixture(
            providers: ["codex": [sample]]))
        try data.write(to: url, options: [.atomic])

        let loaded = PlanUtilizationHistoryStore.load(fileManager: fileManager)

        #expect(loaded[.codex]?.unscoped == [sample])
        #expect(loaded[.codex]?.accounts.isEmpty == true)
    }

    @Test
    func storeRoundTripsAccountBuckets() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileManager = PlanHistoryFileManager(applicationSupportURL: root)
        let aliceSample = PlanUtilizationHistorySample(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            dailyUsedPercent: 10,
            weeklyUsedPercent: 20,
            monthlyUsedPercent: 30)
        let legacySample = PlanUtilizationHistorySample(
            capturedAt: Date(timeIntervalSince1970: 1_699_913_600),
            dailyUsedPercent: 50,
            weeklyUsedPercent: 60,
            monthlyUsedPercent: 70)
        let buckets = PlanUtilizationHistoryBuckets(
            unscoped: [legacySample],
            accounts: ["alice": [aliceSample]])

        PlanUtilizationHistoryStore.save([.codex: buckets], fileManager: fileManager)
        let loaded = PlanUtilizationHistoryStore.load(fileManager: fileManager)

        #expect(loaded == [.codex: buckets])
    }
}

extension UsageStorePlanUtilizationTests {
    @MainActor
    private static func makeStore() -> UsageStore {
        let suiteName = "UsageStorePlanUtilizationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let configStore = testConfigStore(suiteName: suiteName)
        let isolatedSettings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            tokenAccountStore: InMemoryTokenAccountStore())
        return UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: isolatedSettings,
            startupBehavior: .testing)
    }

    private static func makeSnapshot(provider: UsageProvider, email: String) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: provider,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: "plus"))
    }
}

private struct LegacyPlanUtilizationHistoryFileFixture: Codable {
    let providers: [String: [PlanUtilizationHistorySample]]
}

private final class PlanHistoryFileManager: FileManager {
    private let applicationSupportURL: URL

    init(applicationSupportURL: URL) {
        self.applicationSupportURL = applicationSupportURL
        super.init()
    }

    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        if directory == .applicationSupportDirectory, domainMask == .userDomainMask {
            return [self.applicationSupportURL]
        }
        return super.urls(for: directory, in: domainMask)
    }
}
