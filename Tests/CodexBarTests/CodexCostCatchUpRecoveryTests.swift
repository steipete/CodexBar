import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct CodexCostCatchUpRecoveryTests {
    @Test(arguments: [false, true], ["complete", "repeat", "progress", "cycle"])
    func `workers restore a full budget once and keep the terminal stall guard`(
        dashboard: Bool,
        scenario: String) async throws
    {
        let store = try UsageStoreSpendDashboardCodexCostCatchUpTests.makeStore(suite: "recovery-workers")
        defer {
            store.cancelCodexCostCatchUp()
            store.cancelSpendDashboardCodexCostCatchUp()
        }
        store.settings.backgroundWorkLowPowerModePreference = .off
        let accounts = [UsageStoreSpendDashboardCodexCostCatchUpTests.account(
            id: "fixture",
            cacheIdentity: "fixture")]
        let stillStalled = scenario != "complete"
        let keys = switch scenario {
        case "progress": ["advanced", "advanced", "further", "further"]
        case "cycle": ["advanced", "initial"]
        default: ["advanced", "advanced", stillStalled ? "advanced" : "complete"]
        }
        var advances = 0
        var budgets: [TimeInterval] = []
        var sleeps: [TimeInterval] = []
        let initial = CostUsageFetcher.CodexScanCatchUpStatus(
            pending: true,
            progressKey: "initial")
        let advance: @MainActor () -> CostUsageFetcher.CodexScanCatchUpStatus = {
            advances += 1
            return .init(
                pending: advances < keys.count || stillStalled,
                progressKey: keys[min(advances - 1, keys.count - 1)],
                yieldedBeforeFileAttempt: advances != 1)
        }
        store._test_codexCostCatchUpBudgetObserver = { budgets.append($0) }
        if dashboard {
            store._test_spendDashboardCodexCostCatchUpActiveDuration = 1.999
            store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in initial }
            store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { _, _, _ in advance() }
            store._test_spendDashboardCodexCostCatchUpSleepOverride = { sleeps.append($0) }
            store._test_spendDashboardCodexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }
            store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts)
            await store.spendDashboardCodexCostCatchUpTask?.value
        } else {
            store._test_codexCostCatchUpActiveDuration = 1.999
            store._test_codexCostCatchUpStatusOverride = { _ in
                advances >= 3 && !stillStalled ? .init(
                    pending: false,
                    progressKey: "complete") : initial
            }
            store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in advance() }
            store._test_codexCostCatchUpSleepOverride = { sleeps.append($0) }
            store._test_codexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }
            store._test_cachedCodexTokenSnapshotLoaderOverride = { now, _, _ in
                guard advances >= 3, !stillStalled else { return nil }
                return (CostUsageTokenSnapshot(
                    sessionTokens: 0,
                    sessionCostUSD: nil,
                    last30DaysTokens: 0,
                    last30DaysCostUSD: nil,
                    historyCoverageIsEstablished: true,
                    daily: [],
                    updatedAt: now), now, nil)
            }
            store.startCodexCostCatchUpIfNeeded()
            await store.codexCostCatchUpTask?.value
        }
        #expect(advances == keys.count)
        #expect(budgets.count == keys.count)
        #expect(budgets.first == 2)
        #expect(abs((budgets.dropFirst().first ?? 0) - 0.001) < 0.000001)
        if scenario == "cycle" {
            #expect(sleeps.allSatisfy { $0 == 0 })
        } else {
            #expect(budgets.dropFirst(2).first == 2)
            #expect(sleeps.contains { abs($0 - 3.998 * 999) < 0.000001 })
        }
        let activity = dashboard ? store.spendDashboardCodexCostCatchUpActivity : store.codexCostCatchUpActivity
        #expect(activity?.phase == (stillStalled ? .paused : .complete))
        #expect(activity?.pauseReason == (stillStalled ? .noProgress : nil))
    }

    @Test(arguments: [false, true])
    func `a user stop during recovery cooldown prevents the extra pass`(dashboard: Bool) async throws {
        let store = try UsageStoreSpendDashboardCodexCostCatchUpTests.makeStore(suite: "recovery-stop")
        defer {
            store.cancelCodexCostCatchUp()
            store.cancelSpendDashboardCodexCostCatchUp()
        }
        store.settings.backgroundWorkLowPowerModePreference = .off
        let accounts = [UsageStoreSpendDashboardCodexCostCatchUpTests.account(
            id: "fixture",
            cacheIdentity: "fixture")]
        var advances = 0
        let status = CostUsageFetcher.CodexScanCatchUpStatus(
            pending: true,
            progressKey: "same",
            yieldedBeforeFileAttempt: true)
        if dashboard {
            store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in status }
            store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { _, _, _ in advances += 1; return status }
            store._test_spendDashboardCodexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }
            store._test_spendDashboardCodexCostCatchUpSleepOverride = { delay in
                if delay > 0 { store.stopSpendDashboardCodexCostCatchUp() }
            }
            store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts)
            await store.spendDashboardCodexCostCatchUpTask?.value
        } else {
            store._test_codexCostCatchUpStatusOverride = { _ in status }
            store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in advances += 1; return status }
            store._test_cachedCodexTokenSnapshotLoaderOverride = { _, _, _ in nil }
            store._test_codexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }
            store._test_codexCostCatchUpSleepOverride = { delay in
                if delay > 0 { store.stopCodexCostCatchUp() }
            }
            store.startCodexCostCatchUpIfNeeded()
            await store.codexCostCatchUpTask?.value
        }
        #expect(advances == 1)
        #expect((dashboard ? store.spendDashboardCodexCostCatchUpActivity : store.codexCostCatchUpActivity)?
            .pauseReason == .user)
    }

    @Test(arguments: ["unconfirmed", "pending", "scope-mismatch", "unavailable", "new-account", "settings"])
    func `unproven or changed-scope results preserve the paused dashboard`(kind: String) async throws {
        let store = try UsageStoreSpendDashboardCodexCostCatchUpTests.makeStore(suite: "completion-guards")
        defer { store.cancelSpendDashboardCodexCostCatchUp() }
        let accounts = [UsageStoreSpendDashboardCodexCostCatchUpTests.account(
            id: "fixture",
            cacheIdentity: "fixture")]
        var advances = 0
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in .init(
            pending: true,
            progressKey: "same") }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { _, _, _ in
            advances += 1
            return .init(
                pending: true,
                progressKey: "same")
        }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { _ in }
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }
        store.startSpendDashboardCodexCostCatchUpIfNeeded(
            accounts: accounts,
            mode: .accelerated)
        await store.spendDashboardCodexCostCatchUpTask?.value
        let activity = store.spendDashboardCodexCostCatchUpActivity
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            .init(
                pending: kind == "pending",
                progressKey: kind,

                completionIsConfirmed: !["unconfirmed", "scope-mismatch", "unavailable"].contains(kind))
        }
        if kind == "settings" { store.settings.costUsageHistoryDays = 365 }
        let current = kind == "new-account"
            ? [UsageStoreSpendDashboardCodexCostCatchUpTests.account(
                id: "other",
                cacheIdentity: "other")] : accounts
        store.synchronizeSpendDashboardCodexCostCatchUp(accounts: current)
        await store.spendDashboardCodexCostCatchUpCompletionCheckTask?.value
        #expect(store.spendDashboardCodexCostCatchUpActivity == activity)
        #expect(advances == 1)
        #expect(store.spendDashboardCodexCostCatchUpTask == nil)
    }

    @Test
    func `previously complete accounts do not need a new scan to clear another account stall`() async throws {
        let store = try UsageStoreSpendDashboardCodexCostCatchUpTests.makeStore(suite: "completion-multiple")
        defer { store.cancelSpendDashboardCodexCostCatchUp() }
        let accounts = ["one", "two"].map {
            UsageStoreSpendDashboardCodexCostCatchUpTests.account(
                id: $0,
                cacheIdentity: $0)
        }
        var advances = 0
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { account in
            .init(
                pending: account.id == "two",
                progressKey: account.id,

                completionIsConfirmed: account.id == "one")
        }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { _, _, _ in
            advances += 1
            return .init(
                pending: true,
                progressKey: "two")
        }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { _ in }
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }
        store.startSpendDashboardCodexCostCatchUpIfNeeded(
            accounts: accounts,
            mode: .accelerated)
        await store.spendDashboardCodexCostCatchUpTask?.value
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { account in
            .init(
                pending: false,
                progressKey: account.id,

                completionIsConfirmed: true)
        }
        store.synchronizeSpendDashboardCodexCostCatchUp(accounts: accounts)
        await store.spendDashboardCodexCostCatchUpCompletionCheckTask?.value
        #expect(store.spendDashboardCodexCostCatchUpActivity?.phase == .complete)
        #expect(advances == 1)
    }

    @Test(arguments: ["accounts", "settings", "stop", "refresh", "cancel"])
    func `a changed owner cannot be overwritten by a completion read`(action: String) async throws {
        let store = try UsageStoreSpendDashboardCodexCostCatchUpTests.makeStore(suite: "completion-race")
        let reads = SpendDashboardPendingLoads<Void>()
        defer { store.cancelSpendDashboardCodexCostCatchUp(); reads.close() }
        let accounts = [UsageStoreSpendDashboardCodexCostCatchUpTests.account(
            id: "fixture",
            cacheIdentity: "fixture")]
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in .init(
            pending: true,
            progressKey: "same") }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { _, _, _ in .init(
            pending: true,
            progressKey: "same") }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { _ in }
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }
        store.startSpendDashboardCodexCostCatchUpIfNeeded(
            accounts: accounts,
            mode: .accelerated)
        await store.spendDashboardCodexCostCatchUpTask?.value
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            try? await reads.load()
            return .init(
                pending: false,
                progressKey: "complete",

                completionIsConfirmed: true)
        }
        store.synchronizeSpendDashboardCodexCostCatchUp(accounts: accounts)
        let task = try #require(store.spendDashboardCodexCostCatchUpCompletionCheckTask)
        try await reads.waitForPendingCount(1)
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            .init(pending: true, progressKey: "same")
        }
        switch action {
        case "accounts":
            store.synchronizeSpendDashboardCodexCostCatchUp(accounts: [
                UsageStoreSpendDashboardCodexCostCatchUpTests.account(id: "other", cacheIdentity: "other"),
            ])
        case "settings": store.settings.costUsageHistoryDays = 365
        case "stop": store.stopSpendDashboardCodexCostCatchUp()
        case "refresh":
            let previousToken = store.spendDashboardCodexCostCatchUpContext?.token
            store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts)
            #expect(store.spendDashboardCodexCostCatchUpContext?.token != previousToken)
        default: store.cancelSpendDashboardCodexCostCatchUp()
        }
        reads.resume()
        await task.value
        await store.spendDashboardCodexCostCatchUpTask?.value
        let reason = store.spendDashboardCodexCostCatchUpActivity?.pauseReason
        #expect(reason == (action == "cancel" ? nil : action == "stop" ? .user : .noProgress))
        #expect(store.spendDashboardCodexCostCatchUpTask == nil)
    }
}
