import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct UsageStoreSpendDashboardCodexCostCatchUpCompletionTests {
    @Test
    func `confirmed completion retires an automatic worker during its scheduled sleep`() async throws {
        let fixture = try DashboardCatchUpCompletionFixture()
        defer { fixture.close() }
        try await fixture.start()
        let original = try #require(fixture.store.spendDashboardCodexCostCatchUpTask)
        let revision = fixture.store.spendDashboardCodexCostCatchUpRevision
        fixture.completeAllAccounts()

        fixture.store.synchronizeSpendDashboardCodexCostCatchUp(accounts: fixture.accounts)
        try? await SpendDashboardStateWait.until(timeout: .seconds(2)) {
            fixture.store.spendDashboardCodexCostCatchUpActivity?.phase == .complete
        }

        #expect(fixture.store.spendDashboardCodexCostCatchUpActivity?.phase == .complete)
        #expect(fixture.scanPasses == 1)
        #expect(fixture.store.spendDashboardCodexCostCatchUpRevision == revision + 1)
        #expect(!fixture.store.spendDashboardCodexCostCatchUpRestartRequested)
        #expect(original.isCancelled)
        fixture.sleep.close()
        await original.value
        #expect(fixture.store.spendDashboardCodexCostCatchUpTask == nil)
        #expect(fixture.store.spendDashboardCodexCostCatchUpRevision == revision + 1)
    }

    @Test(arguments: ["pending", "unconfirmed"])
    func `unproven completion preserves the original automatic sleep`(kind: String) async throws {
        let fixture = try DashboardCatchUpCompletionFixture()
        defer { fixture.close() }
        try await fixture.start()
        let token = fixture.store.spendDashboardCodexCostCatchUpContext?.token
        let revision = fixture.store.spendDashboardCodexCostCatchUpRevision
        fixture.statuses[fixture.accounts[0].id] = .init(
            pending: kind == "pending", progressKey: kind, completionIsConfirmed: kind == "pending")

        fixture.store.synchronizeSpendDashboardCodexCostCatchUp(accounts: fixture.accounts)
        await fixture.store.spendDashboardCodexCostCatchUpCompletionCheckTask?.value

        #expect(fixture.store.spendDashboardCodexCostCatchUpActivity?.phase == .indexing)
        #expect(fixture.store.spendDashboardCodexCostCatchUpContext?.token == token)
        #expect(fixture.store.spendDashboardCodexCostCatchUpRevision == revision)
        #expect(fixture.sleep.pendingCount == 1)
        #expect(fixture.scanPasses == 1)
        #expect(fixture.statusReads == 2)
    }

    @Test
    func `all account caches must confirm completion before the worker retires`() async throws {
        let fixture = try DashboardCatchUpCompletionFixture(accountCount: 2)
        defer { fixture.close() }
        try await fixture.start()
        let original = try #require(fixture.store.spendDashboardCodexCostCatchUpTask)
        fixture.statuses[fixture.accounts[0].id] = .init(
            pending: false, progressKey: "first-complete", completionIsConfirmed: true)
        fixture.store.synchronizeSpendDashboardCodexCostCatchUp(accounts: fixture.accounts)
        await fixture.store.spendDashboardCodexCostCatchUpCompletionCheckTask?.value
        #expect(fixture.store.spendDashboardCodexCostCatchUpActivity?.phase == .indexing)
        #expect(!original.isCancelled)
        #expect(fixture.scanPasses == 1)

        fixture.completeAllAccounts()
        fixture.store.synchronizeSpendDashboardCodexCostCatchUp(accounts: fixture.accounts)
        await fixture.store.spendDashboardCodexCostCatchUpCompletionCheckTask?.value
        #expect(fixture.store.spendDashboardCodexCostCatchUpActivity?.phase == .complete)
        #expect(fixture.scanPasses == 1)
        #expect(original.isCancelled)
        fixture.sleep.close()
        await original.value
    }

    @Test(arguments: ["stop", "disabled", "settings", "replacement", "mode"])
    func `completion observed after invalidation cannot publish into the new state`(kind: String) async throws {
        let fixture = try DashboardCatchUpCompletionFixture()
        let reads = SpendDashboardPendingLoads<CostUsageFetcher.CodexScanCatchUpStatus>()
        defer { fixture.close(); reads.close() }
        try await fixture.start()
        let original = try #require(fixture.store.spendDashboardCodexCostCatchUpTask)
        fixture.store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            await (try? reads.load()) ?? .init(pending: false, progressKey: "unavailable")
        }
        fixture.store.synchronizeSpendDashboardCodexCostCatchUp(accounts: fixture.accounts)
        let check = try #require(fixture.store.spendDashboardCodexCostCatchUpCompletionCheckTask)
        try await reads.waitForPendingCount(1)
        let revision = fixture.store.spendDashboardCodexCostCatchUpRevision
        switch kind {
        case "stop": fixture.store.stopSpendDashboardCodexCostCatchUp()
        case "disabled":
            fixture.store.settings.costUsageEnabled = false
            fixture.store.synchronizeSpendDashboardCodexCostCatchUp(accounts: fixture.accounts)
        case "settings": fixture.store.settings.costUsageHistoryDays = 500
        case "mode":
            fixture.store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: fixture.accounts, mode: .accelerated)
        default:
            fixture.store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
                .init(pending: true, progressKey: "replacement")
            }
            let other = UsageStoreSpendDashboardCodexCostCatchUpTests.account(id: "other", cacheIdentity: "other")
            fixture.store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: [other])
        }
        reads.resume(returning: .init(pending: false, progressKey: "complete", completionIsConfirmed: true))
        await check.value
        #expect(fixture.store.spendDashboardCodexCostCatchUpActivity?.phase != .complete)
        #expect(fixture.store.spendDashboardCodexCostCatchUpRevision == revision)
        if kind == "stop" { #expect(fixture.store.spendDashboardCodexCostCatchUpActivity?.pauseReason == .user) }
        fixture.store.cancelSpendDashboardCodexCostCatchUp()
        fixture.sleep.close()
        await original.value
    }

    @Test(arguments: [true, false])
    func `synchronization during a partial status read rechecks changed accounts`(completes: Bool) async throws {
        let fixture = try DashboardCatchUpCompletionFixture(accountCount: 2)
        let reads = SpendDashboardPendingLoads<Void>()
        defer { fixture.close(); reads.close() }
        try await fixture.start()
        let original = try #require(fixture.store.spendDashboardCodexCostCatchUpTask)
        let revision = fixture.store.spendDashboardCodexCostCatchUpRevision
        fixture.statuses[fixture.accounts[1].id] = .init(
            pending: false, progressKey: "second-complete", completionIsConfirmed: true)
        if !completes { fixture.completeAllAccounts() }
        var checkReads = 0
        fixture.store._test_spendDashboardCodexCostCatchUpStatusOverride = { account in
            checkReads += 1
            let captured = fixture.statuses[account.id] ?? .init(pending: true, progressKey: "missing")
            if checkReads == 2 { try? await reads.load() }
            return captured
        }
        fixture.store.synchronizeSpendDashboardCodexCostCatchUp(accounts: fixture.accounts)
        let check = try #require(fixture.store.spendDashboardCodexCostCatchUpCompletionCheckTask)
        try await reads.waitForPendingCount(1)
        if completes {
            fixture.completeAllAccounts()
        } else {
            fixture.statuses[fixture.accounts[0].id] = .init(pending: true, progressKey: "fresh-tail")
        }
        for _ in 0..<3 {
            fixture.store.synchronizeSpendDashboardCodexCostCatchUp(accounts: fixture.accounts)
        }
        #expect(checkReads == 2)
        reads.resume()
        await check.value

        #expect((fixture.store.spendDashboardCodexCostCatchUpActivity?.phase == .complete) == completes)
        #expect(fixture.store.spendDashboardCodexCostCatchUpRevision == revision + (completes ? 1 : 0))
        #expect(original.isCancelled == completes)
        #expect(checkReads == 4)
        #expect(fixture.scanPasses == 1)
        fixture.close()
        await original.value
    }

    @Test
    func `repeated synchronization coalesces its in-flight completion read`() async throws {
        let fixture = try DashboardCatchUpCompletionFixture()
        let reads = SpendDashboardPendingLoads<CostUsageFetcher.CodexScanCatchUpStatus>()
        defer { fixture.close(); reads.close() }
        try await fixture.start()
        var checkReads = 0
        fixture.store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            checkReads += 1
            return await (try? reads.load()) ?? .init(pending: false, progressKey: "unavailable")
        }
        for _ in 0..<3 {
            fixture.store.synchronizeSpendDashboardCodexCostCatchUp(accounts: fixture.accounts)
        }
        let check = try #require(fixture.store.spendDashboardCodexCostCatchUpCompletionCheckTask)
        try await reads.waitForPendingCount(1)
        #expect(checkReads == 1)
        reads.resume(returning: .init(pending: true, progressKey: "still-pending"))
        await check.value
        #expect(fixture.scanPasses == 1)
        #expect(fixture.sleep.pendingCount == 1)
        #expect(fixture.store.spendDashboardCodexCostCatchUpCompletionCheckTask == nil)
    }

    @Test
    func `a completion read that outlives its sleep cannot retire a running pass`() async throws {
        let fixture = try DashboardCatchUpCompletionFixture()
        let reads = SpendDashboardPendingLoads<CostUsageFetcher.CodexScanCatchUpStatus>()
        let scan = SpendDashboardPendingLoads<CostUsageFetcher.CodexScanCatchUpStatus>()
        defer { fixture.close(); reads.close(); scan.close() }
        try await fixture.start()
        let original = try #require(fixture.store.spendDashboardCodexCostCatchUpTask)
        let token = fixture.store.spendDashboardCodexCostCatchUpContext?.token
        fixture.store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            await (try? reads.load()) ?? .init(pending: false, progressKey: "unavailable")
        }
        fixture.store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { [weak fixture] _, _, _ in
            guard let fixture else { throw CancellationError() }
            fixture.scanPasses += 1
            return try await scan.load()
        }
        fixture.store.synchronizeSpendDashboardCodexCostCatchUp(accounts: fixture.accounts)
        let check = try #require(fixture.store.spendDashboardCodexCostCatchUpCompletionCheckTask)
        try await reads.waitForPendingCount(1)
        fixture.sleep.resume()
        try await scan.waitForPendingCount(1)
        #expect(check.isCancelled)
        reads.resume(returning: .init(pending: false, progressKey: "complete", completionIsConfirmed: true))
        await check.value
        #expect(fixture.store.spendDashboardCodexCostCatchUpActivity?.phase == .indexing)
        #expect(fixture.store.spendDashboardCodexCostCatchUpContext?.token == token)
        #expect(fixture.store.spendDashboardCodexCostCatchUpPassIsRunning)
        #expect(!original.isCancelled)
        #expect(fixture.scanPasses == 2)
        fixture.store.stopSpendDashboardCodexCostCatchUp()
        scan.resume(returning: .init(pending: true, progressKey: "next-pass"))
        await original.value
        #expect(fixture.store.spendDashboardCodexCostCatchUpActivity?.pauseReason == .user)
    }

    @Test
    func `a cancelled read cannot clear the check started in the next sleep`() async throws {
        let fixture = try DashboardCatchUpCompletionFixture()
        let reads = SpendDashboardPendingLoads<CostUsageFetcher.CodexScanCatchUpStatus>()
        let scan = SpendDashboardPendingLoads<CostUsageFetcher.CodexScanCatchUpStatus>()
        defer { fixture.close(); reads.close(); scan.close() }
        try await fixture.start()
        let original = try #require(fixture.store.spendDashboardCodexCostCatchUpTask)
        fixture.store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            await (try? reads.load()) ?? .init(pending: false, progressKey: "unavailable")
        }
        fixture.store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { [weak fixture] _, _, _ in
            guard let fixture else { throw CancellationError() }
            fixture.scanPasses += 1
            return try await scan.load()
        }
        fixture.store.synchronizeSpendDashboardCodexCostCatchUp(accounts: fixture.accounts)
        let oldCheck = try #require(fixture.store.spendDashboardCodexCostCatchUpCompletionCheckTask)
        try await reads.waitForPendingCount(1)
        fixture.sleep.resume()
        try await scan.waitForPendingCount(1)
        scan.resume(returning: .init(pending: true, progressKey: "next-pass"))
        try await fixture.sleep.waitForPendingCount(1)
        fixture.store.synchronizeSpendDashboardCodexCostCatchUp(accounts: fixture.accounts)
        let newCheck = try #require(fixture.store.spendDashboardCodexCostCatchUpCompletionCheckTask)
        try await reads.waitForPendingCount(2)
        reads.resume(returning: .init(pending: false, progressKey: "complete", completionIsConfirmed: true))
        await oldCheck.value
        #expect(oldCheck.isCancelled)
        #expect(!newCheck.isCancelled)
        #expect(fixture.store.spendDashboardCodexCostCatchUpCompletionCheckTask != nil)
        #expect(fixture.store.spendDashboardCodexCostCatchUpActivity?.phase == .indexing)
        #expect(!original.isCancelled)
        reads.resume(returning: .init(pending: true, progressKey: "still-pending"))
        await newCheck.value
        #expect(fixture.store.spendDashboardCodexCostCatchUpCompletionCheckTask == nil)
        fixture.close()
        await original.value
    }

    @Test(arguments: ["complete", "stop", "settings", "accounts"])
    func `stalled worker completion uses the same coalescing and invalidation guards`(kind: String) async throws {
        let fixture = try DashboardCatchUpCompletionFixture()
        let reads = SpendDashboardPendingLoads<CostUsageFetcher.CodexScanCatchUpStatus>()
        defer { fixture.close(); reads.close() }
        fixture.store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { account, _, _ in
            .init(pending: true, progressKey: "initial-\(account.id)")
        }
        fixture.store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: fixture.accounts)
        await fixture.store.spendDashboardCodexCostCatchUpTask?.value
        #expect(fixture.store.spendDashboardCodexCostCatchUpActivity?.pauseReason == .noProgress)
        let revision = fixture.store.spendDashboardCodexCostCatchUpRevision
        fixture.store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            await (try? reads.load()) ?? .init(pending: false, progressKey: "unavailable")
        }
        for _ in 0..<3 {
            fixture.store.synchronizeSpendDashboardCodexCostCatchUp(accounts: fixture.accounts)
        }
        let check = try #require(fixture.store.spendDashboardCodexCostCatchUpCompletionCheckTask)
        try await reads.waitForPendingCount(1)
        switch kind {
        case "stop": fixture.store.stopSpendDashboardCodexCostCatchUp()
        case "settings": fixture.store.settings.costUsageHistoryDays = 500
        case "accounts":
            let other = UsageStoreSpendDashboardCodexCostCatchUpTests.account(id: "other", cacheIdentity: "other")
            fixture.store.synchronizeSpendDashboardCodexCostCatchUp(accounts: [other])
        default: break
        }
        reads.resume(returning: .init(pending: false, progressKey: "complete", completionIsConfirmed: true))
        await check.value
        #expect(fixture.store.spendDashboardCodexCostCatchUpTask == nil)
        #expect(fixture.store.spendDashboardCodexCostCatchUpCompletionCheckTask == nil)
        #expect((fixture.store.spendDashboardCodexCostCatchUpActivity?.phase == .complete) == (kind == "complete"))
        #expect(fixture.store.spendDashboardCodexCostCatchUpRevision == revision + (kind == "complete" ? 1 : 0))
        if kind == "stop" { #expect(fixture.store.spendDashboardCodexCostCatchUpActivity?.pauseReason == .user) }
    }

    @Test
    func `synchronization during a scan waits for the pass instead of checking completion`() async throws {
        let fixture = try DashboardCatchUpCompletionFixture()
        let scan = SpendDashboardPendingLoads<CostUsageFetcher.CodexScanCatchUpStatus>()
        defer { fixture.close(); scan.close() }
        fixture.store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { _, _, _ in try await scan.load() }
        fixture.store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: fixture.accounts)
        try await scan.waitForPendingCount(1)
        fixture.completeAllAccounts()
        fixture.store.synchronizeSpendDashboardCodexCostCatchUp(accounts: fixture.accounts)
        #expect(fixture.store.spendDashboardCodexCostCatchUpCompletionCheckTask == nil)
        #expect(fixture.statusReads == 1)
        #expect(fixture.store.spendDashboardCodexCostCatchUpPassIsRunning)
        fixture.store.stopSpendDashboardCodexCostCatchUp()
        scan.resume(returning: .init(pending: true, progressKey: "advanced"))
        await fixture.store.spendDashboardCodexCostCatchUpTask?.value
        #expect(fixture.store.spendDashboardCodexCostCatchUpActivity?.pauseReason == .user)
    }
}

@MainActor
private final class DashboardCatchUpCompletionFixture {
    let store: UsageStore
    let accounts: [CodexSpendScanRequest]
    let sleep = SpendDashboardPendingLoads<Void>()
    var statuses: [String: CostUsageFetcher.CodexScanCatchUpStatus] = [:]
    var scanPasses = 0
    var statusReads = 0
    var scheduledDelay: TimeInterval?

    init(accountCount: Int = 1) throws {
        self.store = try UsageStoreSpendDashboardCodexCostCatchUpTests.makeStore(suite: "sleep-completion")
        self.accounts = (0..<accountCount).map {
            UsageStoreSpendDashboardCodexCostCatchUpTests.account(
                id: "account-\($0)", cacheIdentity: "cache-account-\($0)")
        }
        self.statuses = Dictionary(uniqueKeysWithValues: self.accounts.map {
            ($0.id, .init(pending: true, progressKey: "initial-\($0.id)"))
        })
        self.store.settings.backgroundWorkLowPowerModePreference = .off
        self.store._test_spendDashboardCodexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }
        self.store._test_spendDashboardCodexCostCatchUpActiveDuration = 2
        self.store._test_spendDashboardCodexCostCatchUpStatusOverride = { [weak self] account in
            guard let self else { return .init(pending: false, progressKey: "unavailable") }
            self.statusReads += 1
            return self.statuses[account.id] ?? .init(pending: false, progressKey: "unavailable")
        }
        self.store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { [weak self] account, _, _ in
            guard let self else { throw CancellationError() }
            self.scanPasses += 1
            let status = CostUsageFetcher.CodexScanCatchUpStatus(
                pending: true, progressKey: "advanced-\(account.id)")
            self.statuses[account.id] = status
            return status
        }
        self.store._test_spendDashboardCodexCostCatchUpSleepOverride = { [weak self] delay in
            guard let self, delay > 0 else { return }
            self.scheduledDelay = delay
            try await self.sleep.load()
        }
    }

    func start() async throws {
        self.store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: self.accounts)
        try await self.sleep.waitForPendingCount(1)
        #expect(self.scheduledDelay == 1998)
        #expect(self.scanPasses == 1)
        #expect(self.store.spendDashboardCodexCostCatchUpActivity?.phase == .indexing)
    }

    func completeAllAccounts() {
        for account in self.accounts {
            self.statuses[account.id] = .init(
                pending: false, progressKey: "complete-\(account.id)", completionIsConfirmed: true)
        }
    }

    func close() {
        self.store.stopSharedSpendDashboardPublication()
        self.sleep.close()
    }
}
