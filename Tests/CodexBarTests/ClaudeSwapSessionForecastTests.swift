import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct ClaudeSwapSessionForecastTests {
    @Test
    func `fresh measurements record history under each account fingerprint`() async throws {
        let fixture = try CodexWorkspacesNavigationFixture(userDefaults: InMemoryUserDefaults())
        defer { fixture.cleanup() }
        let store = fixture.store
        let accounts = Self.accounts([
            Self.row(number: 1, email: "one@example.com", sessionUsed: 30, weeklyUsed: 40),
            Self.row(number: 2, email: "two@example.com", sessionUsed: 50, weeklyUsed: 60),
        ])

        await store.recordClaudeSwapPlanUtilizationHistory(accounts)

        let buckets = try #require(store.planUtilizationHistory[.claude])
        let keys = try accounts.map { try #require($0.historyAccountKey) }
        #expect(Set(buckets.accounts.keys) == Set(keys))
        #expect(keys.allSatisfy { !$0.contains("example.com") })
        #expect(buckets.preferredAccountKey == nil)
        #expect(buckets.unscoped.isEmpty)
        let session = try #require(buckets.histories(for: keys[1]).first { $0.name == .session })
        #expect(session.entries.map(\.usedPercent) == [50])
        #expect(session.entries.map(\.capturedAt) == [Self.fetchedAt])
    }

    @Test
    func `tcr history requires email and organization and uses the shared account key`() async throws {
        let fixture = try CodexWorkspacesNavigationFixture(userDefaults: InMemoryUserDefaults())
        defer { fixture.cleanup() }
        let rows = [
            Self.row(number: 1, email: " One@Example.com ", organizationUuid: "ORG-A", sessionUsed: 30),
            Self.row(number: 2, email: "one@example.com", organizationUuid: "org-b", sessionUsed: 80),
            Self.row(number: 3, email: "one@example.com", sessionUsed: 50),
            Self.row(number: 4, email: "", organizationUuid: "org-a", sessionUsed: 60),
        ]
        let accounts = Self.accounts(rows, source: .tcr)
        #expect(accounts[0].historyAccountKey == Self.accounts(rows)[0].historyAccountKey)
        #expect(accounts[0].historyAccountKey != accounts[1].historyAccountKey)
        #expect(accounts[2].historyAccountKey == nil)
        #expect(accounts[3].historyAccountKey == nil)
        await fixture.store.recordClaudeSwapPlanUtilizationHistory(accounts)
        #expect(fixture.store.planUtilizationHistory[.claude]?.accounts.count == 2)
        #expect(fixture.store.claudeSwapPlanUtilizationHistorySelection(for: accounts[0]).histories
            .first { $0.name == .session }?.entries.map(\.usedPercent) == [30])
        #expect(fixture.store.claudeSwapPlanUtilizationHistorySelection(for: accounts[1]).histories
            .first { $0.name == .session }?.entries.map(\.usedPercent) == [80])
        #expect(fixture.store.claudeSwapPlanUtilizationHistorySelection(for: accounts[2]).histories.isEmpty)
    }

    @Test
    func `last known and unavailable rows record nothing`() async throws {
        let fixture = try CodexWorkspacesNavigationFixture(userDefaults: InMemoryUserDefaults())
        defer { fixture.cleanup() }
        let store = fixture.store
        let lastGood = ClaudeSwapLastGoodUsage(
            measurement: ClaudeSwapUsageMeasurement(
                fiveHour: ClaudeSwapUsageWindow(usedPercent: 70, resetsAt: Self.sessionReset),
                sevenDay: ClaudeSwapUsageWindow(usedPercent: 80, resetsAt: Self.weeklyReset)),
            fetchedAt: Self.fetchedAt.addingTimeInterval(-3600))
        let accounts = Self.accounts([
            Self.row(number: 1, email: "one@example.com", status: .tokenExpired, lastGoodUsage: lastGood),
            Self.row(number: 2, email: "two@example.com", status: .unavailable, sessionUsed: 100, weeklyUsed: 90),
        ])

        await store.recordClaudeSwapPlanUtilizationHistory(accounts)

        #expect(store.planUtilizationHistory[.claude] == nil)
    }

    @Test
    func `recording swap history fires no limit reset detection`() async throws {
        let fixture = try CodexWorkspacesNavigationFixture(userDefaults: InMemoryUserDefaults())
        defer { fixture.cleanup() }
        let store = fixture.store
        let beforeReset = Self.accounts([Self.row(number: 1, email: "one@example.com", sessionUsed: 100)])
        let resetAt = Self.sessionReset.addingTimeInterval(60)
        let afterReset = Self.accounts(
            [Self.row(
                number: 1,
                email: "one@example.com",
                sessionUsed: 0,
                sessionReset: Self.sessionReset.addingTimeInterval(18000),
                fetchedAt: resetAt)],
            now: resetAt)

        await store.recordClaudeSwapPlanUtilizationHistory(beforeReset)
        await store.recordClaudeSwapPlanUtilizationHistory(afterReset)

        #expect(store.settings.userDefaults.object(forKey: UsageStore.sessionLimitResetDetectorDefaultsKey) == nil)
    }

    @Test(arguments: ClaudeSwapAccountSource.allCases)
    func `account card shows the session forecast from its own history`(source: ClaudeSwapAccountSource) throws {
        let fixture = try CodexWorkspacesNavigationFixture(userDefaults: InMemoryUserDefaults())
        defer { fixture.cleanup() }
        let store = fixture.store
        let history = SessionEquivalentForecastTests.historyFixture(burns: [4, 8, 6])
        let now = history.currentSessionReset.addingTimeInterval(-3600)
        let account = try #require(Self.accounts(
            [Self.row(
                number: 1,
                email: "one@example.com",
                organizationUuid: "fixture-org",
                sessionUsed: 20,
                weeklyUsed: 60,
                sessionReset: history.currentSessionReset,
                weeklyReset: now.addingTimeInterval(2 * 24 * 3600),
                fetchedAt: now)],
            source: source,
            now: now).first)
        let accountKey = try #require(account.historyAccountKey)
        var buckets = PlanUtilizationHistoryBuckets()
        buckets.setHistories(history.histories, for: accountKey)
        store.planUtilizationHistory[.claude] = buckets

        func forecast(_ selection: PlanUtilizationHistorySelection?) -> SessionEquivalentForecast? {
            store.menuCardInput(
                for: .claude,
                context: ClaudeSwapAccountMenuDisplay.cardContext(
                    for: account,
                    planLabel: nil,
                    adapterError: nil,
                    switchError: nil,
                    historySelection: selection),
                now: now).sessionEquivalentForecast
        }

        #expect(forecast(nil) == nil)
        #expect(forecast(store.claudeSwapPlanUtilizationHistorySelection(for: account)) != nil)
    }

    @Test
    func `ambient history never falls back to a swap bucket`() async throws {
        let fixture = try CodexWorkspacesNavigationFixture(userDefaults: InMemoryUserDefaults())
        defer { fixture.cleanup() }
        let store = fixture.store
        await store.recordClaudeSwapPlanUtilizationHistory(
            Self.accounts([Self.row(number: 1, email: "one@example.com", sessionUsed: 30)]))
        #expect(store.planUtilizationHistory[.claude]?.accounts.isEmpty == false)

        #expect(store.planUtilizationHistorySelection(for: .claude).histories.isEmpty)
    }

    @Test
    func `workspace history stays separate and follows an account to a new slot`() async throws {
        let fixture = try CodexWorkspacesNavigationFixture(userDefaults: InMemoryUserDefaults())
        defer { fixture.cleanup() }
        let store = fixture.store
        let accounts = Self.accounts([
            Self.row(number: 1, email: " Same@Example.com ", organizationUuid: "workspace-a", sessionUsed: 30),
            Self.row(number: 2, email: "same@example.com", organizationUuid: "workspace-b", sessionUsed: 80),
        ])
        await store.recordClaudeSwapPlanUtilizationHistory(accounts)
        let first = try #require(accounts.first)
        let second = try #require(accounts.last)
        #expect(first.historyAccountKey != second.historyAccountKey)
        #expect(store.claudeSwapPlanUtilizationHistorySelection(for: first).histories
            .first { $0.name == .session }?.entries.map(\.usedPercent) == [30])
        #expect(store.claudeSwapPlanUtilizationHistorySelection(for: second).histories
            .first { $0.name == .session }?.entries.map(\.usedPercent) == [80])

        let moved = try #require(Self.accounts([
            Self.row(number: 7, email: "same@example.com", organizationUuid: "WORKSPACE-A", sessionUsed: 40),
        ]).first)
        #expect(moved.id != first.id)
        #expect(moved.historyAccountKey == first.historyAccountKey)
        #expect(store.claudeSwapPlanUtilizationHistorySelection(for: moved).histories
            == store.claudeSwapPlanUtilizationHistorySelection(for: first).histories)
        await store.recordClaudeSwapPlanUtilizationHistory([moved])
        #expect(store.planUtilizationHistory[.claude]?.accounts.count == 2)
        #expect(store.claudeSwapPlanUtilizationHistorySelection(for: first).histories
            .first { $0.name == .session }?.entries.map(\.usedPercent) == [40])
        #expect(store.claudeSwapPlanUtilizationHistorySelection(for: second).histories
            .first { $0.name == .session }?.entries.map(\.usedPercent) == [80])
    }

    @Test
    func `swap history preserves ambient history and the shared sample cap`() async throws {
        let fixture = try CodexWorkspacesNavigationFixture(userDefaults: InMemoryUserDefaults())
        defer { fixture.cleanup() }
        let store = fixture.store
        let account = try #require(Self.accounts([
            Self.row(number: 1, email: "one@example.com", sessionUsed: 30),
        ]).first)
        let key = try #require(account.historyAccountKey)
        let cap = UsageStore._planUtilizationMaxSamplesForTesting
        let prior = (1...cap).reversed().map {
            PlanUtilizationHistoryEntry(
                capturedAt: Self.fetchedAt.addingTimeInterval(-Double($0) * 3600),
                usedPercent: 10,
                resetsAt: Self.sessionReset)
        }
        let series = PlanUtilizationSeriesHistory(name: .session, windowMinutes: 300, entries: prior)
        var buckets = PlanUtilizationHistoryBuckets()
        buckets.setHistories([series], for: key)
        buckets.setHistories([series], for: "ambient")
        buckets.preferredAccountKey = "ambient"
        store.planUtilizationHistory[.claude] = buckets
        let ambientBefore = store.planUtilizationHistorySelection(for: .claude)
        await store.recordClaudeSwapPlanUtilizationHistory([account])
        let retained = try #require(store.claudeSwapPlanUtilizationHistorySelection(for: account).histories
            .first { $0.name == .session })
        #expect(retained.entries.count == cap)
        #expect(retained.entries.first == prior[1])
        #expect(retained.entries.last?.capturedAt == Self.fetchedAt)
        #expect(store.planUtilizationHistorySelection(for: .claude).histories == ambientBefore.histories)
        #expect(store.planUtilizationHistorySelection(for: .claude).accountKey == ambientBefore.accountKey)
        let revision = store.planUtilizationHistoryRevision
        await store.recordClaudeSwapPlanUtilizationHistory([account])
        #expect(store.planUtilizationHistoryRevision == revision)

        // A swap bucket must not block the ambient account's first unscoped-history adoption.
        buckets.accounts.removeValue(forKey: "ambient")
        buckets.unscoped = [series]
        buckets.preferredAccountKey = nil
        store.planUtilizationHistory[.claude] = buckets
        store.snapshots[.claude] = UsageStorePlanUtilizationTests.makeSnapshot(
            provider: .claude, email: "ambient@example.com")
        #expect(store.planUtilizationHistorySelection(for: .claude).histories == [series])
        #expect(store.planUtilizationHistory[.claude]?.unscoped.isEmpty == true)
        #expect(store.claudeSwapPlanUtilizationHistorySelection(for: account).histories == [series])
    }

    // MARK: - Fixtures

    private static let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private static let sessionReset = fetchedAt.addingTimeInterval(3600)
    private static let weeklyReset = fetchedAt.addingTimeInterval(3 * 24 * 3600)

    private static func row(
        number: Int,
        email: String,
        organizationUuid: String = "",
        status: ClaudeSwapUsageStatus = .ok,
        sessionUsed: Double? = nil,
        weeklyUsed: Double = 40,
        sessionReset: Date = sessionReset,
        weeklyReset: Date = weeklyReset,
        fetchedAt: Date = fetchedAt,
        lastGoodUsage: ClaudeSwapLastGoodUsage? = nil) -> ClaudeSwapAccountRow
    {
        ClaudeSwapAccountRow(
            number: number,
            email: email,
            organizationUuid: organizationUuid,
            isActive: number == 1,
            usageStatus: status,
            fiveHour: sessionUsed.map { ClaudeSwapUsageWindow(usedPercent: $0, resetsAt: sessionReset) },
            sevenDay: sessionUsed == nil ? nil : ClaudeSwapUsageWindow(usedPercent: weeklyUsed, resetsAt: weeklyReset),
            usageFetchedAt: fetchedAt,
            lastGoodUsage: lastGoodUsage)
    }

    private static func accounts(
        _ rows: [ClaudeSwapAccountRow],
        source: ClaudeSwapAccountSource = .claudeSwap,
        now: Date = fetchedAt) -> [ProviderAccountUsageSnapshot]
    {
        ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(activeAccountNumber: 1, accounts: rows),
            source: source,
            now: now)
    }
}
