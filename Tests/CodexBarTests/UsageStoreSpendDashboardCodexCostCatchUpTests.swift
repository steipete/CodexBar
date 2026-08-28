import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct UsageStoreSpendDashboardCodexCostCatchUpTests {
    @Test
    func `dashboard catch-up advances every account cache and publishes a reload revision`() async throws {
        let store = try Self.makeStore(suite: "all-accounts")
        let accounts = [
            Self.account(id: "first", cacheIdentity: "cache-first"),
            Self.account(id: "second", cacheIdentity: "cache-second"),
        ]
        let baselineConfiguration = SpendDashboardSource.configuration(settings: store.settings, store: store)
        var completedCacheIdentities: Set<String> = []
        var statusAccounts: [String] = []
        var advancedAccounts: [String] = []
        var receivedHistoryDays: [Int] = []
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { account in
            statusAccounts.append(account.id)
            let complete = completedCacheIdentities.contains(account.cacheIdentity)
            return Self.status(
                pending: !complete,
                key: complete ? "complete-\(account.id)" : "pending-\(account.id)",
                processedBytes: complete ? 100 : 25)
        }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { account, _, historyDays in
            advancedAccounts.append(account.id)
            receivedHistoryDays.append(historyDays)
            completedCacheIdentities.insert(account.cacheIdentity)
            return Self.status(
                pending: false,
                key: "complete-\(account.id)",
                processedBytes: 100)
        }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { _ in
            await Task.yield()
        }
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = {
            (.battery, true, .serious)
        }

        store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts, mode: .accelerated)
        await Self.waitUntil {
            store.spendDashboardCodexCostCatchUpTask == nil
        }

        let replacementConfiguration = SpendDashboardSource.configuration(settings: store.settings, store: store)
        #expect(statusAccounts == ["first", "second"])
        #expect(advancedAccounts == ["first", "second"])
        #expect(receivedHistoryDays == [SpendDashboardSource.scanDays, SpendDashboardSource.scanDays])
        #expect(store.spendDashboardCodexCostCatchUpRevision == 1)
        #expect(baselineConfiguration.sourceRevisions != replacementConfiguration.sourceRevisions)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.phase == .complete)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.mode == .accelerated)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.fractionCompleted == 1)
    }

    @Test(arguments: [1, 7, 29, 123, 248, 365])
    func `dashboard catch-up uses the spend scan window`(historyDays: Int) async throws {
        let receivedHistoryDays = try await Self.receivedHistoryDays(
            configuredHistoryDays: historyDays,
            suite: "configured-\(historyDays)")

        #expect(receivedHistoryDays == SpendDashboardSource.scanDays)
    }

    @Test
    func `history days below the scan window keep the active catch-up context`() throws {
        let store = try Self.makeStore(suite: "history-context")
        let accounts = [Self.account(id: "account", cacheIdentity: "cache-account")]
        store.settings.costUsageHistoryDays = 30
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            Self.status(pending: true, key: "pending", processedBytes: 25)
        }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { _ in
            try await Task.sleep(for: .seconds(60))
        }

        store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts, mode: .accelerated)
        let originalToken = try #require(store.spendDashboardCodexCostCatchUpToken)

        store.settings.costUsageHistoryDays = 123
        store.synchronizeSpendDashboardCodexCostCatchUp(accounts: accounts)
        let replacementToken = try #require(store.spendDashboardCodexCostCatchUpToken)

        #expect(replacementToken == originalToken)
        store.cancelSpendDashboardCodexCostCatchUp()
    }

    @Test
    func `a stalled account cache does not prevent a sibling cache from advancing`() async throws {
        let store = try Self.makeStore(suite: "stalled-sibling")
        let accounts = [
            Self.account(id: "stalled", cacheIdentity: "cache-stalled"),
            Self.account(id: "healthy", cacheIdentity: "cache-healthy"),
        ]
        var advancedAccounts: [String] = []
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { account in
            Self.status(
                pending: true,
                key: "pending-\(account.id)",
                processedBytes: 25)
        }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { account, _, _ in
            advancedAccounts.append(account.id)
            if account.id == "stalled" {
                return Self.status(
                    pending: true,
                    key: "pending-stalled",
                    processedBytes: 25)
            }
            return Self.status(
                pending: false,
                key: "complete-healthy",
                processedBytes: 100)
        }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { _ in
            await Task.yield()
        }
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = {
            (.ac, false, .nominal)
        }

        store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts, mode: .accelerated)
        await Self.waitUntil {
            store.spendDashboardCodexCostCatchUpTask == nil
        }

        #expect(advancedAccounts == ["stalled", "healthy"])
        #expect(store.spendDashboardCodexCostCatchUpRevision == 1)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.phase == .paused)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.pauseReason == .noProgress)
    }

    @Test
    func `a no-progress pass does not publish a reload revision`() async throws {
        let store = try Self.makeStore(suite: "no-progress-revision")
        let accounts = [Self.account(id: "stalled", cacheIdentity: "cache-stalled")]
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            Self.status(pending: true, key: "unchanged", processedBytes: 25)
        }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { _, _, _ in
            Self.status(pending: true, key: "unchanged", processedBytes: 25)
        }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { _ in
            await Task.yield()
        }
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = {
            (.ac, false, .nominal)
        }

        store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts, mode: .accelerated)
        await Self.waitUntil {
            store.spendDashboardCodexCostCatchUpTask == nil
        }

        #expect(store.spendDashboardCodexCostCatchUpRevision == 0)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.phase == .paused)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.pauseReason == .noProgress)
        #expect(store.spendDashboardCodexCostCatchUpRetryNotBefore != nil)
        #expect(store.spendDashboardCodexCostCatchUpRetryScopeSignature != nil)

        store.synchronizeSpendDashboardCodexCostCatchUp(accounts: accounts)

        #expect(store.spendDashboardCodexCostCatchUpTask == nil)

        let replacementAccounts = [Self.account(id: "replacement", cacheIdentity: "cache-replacement")]
        store.synchronizeSpendDashboardCodexCostCatchUp(accounts: replacementAccounts)

        #expect(store.spendDashboardCodexCostCatchUpTask != nil)
        #expect(store.spendDashboardCodexCostCatchUpRetryNotBefore == nil)
        #expect(store.spendDashboardCodexCostCatchUpRetryScopeSignature == nil)
        store.cancelSpendDashboardCodexCostCatchUp()
    }

    @Test
    func `manual retry bypasses a no-progress background backoff`() async throws {
        let store = try Self.makeStore(suite: "manual-no-progress-retry")
        let accounts = [Self.account(id: "stalled", cacheIdentity: "cache-stalled")]
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            Self.status(
                pending: true,
                key: "unchanged",
                processedBytes: 25)
        }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { _, _, _ in
            Self.status(pending: true, key: "unchanged", processedBytes: 25)
        }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { _ in
            await Task.yield()
        }

        store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts, mode: .accelerated)
        await Self.waitUntil {
            store.spendDashboardCodexCostCatchUpTask == nil
        }
        #expect(store.spendDashboardCodexCostCatchUpRetryNotBefore != nil)

        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            Self.status(pending: false, key: "complete", processedBytes: 100)
        }
        store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts, mode: .accelerated)
        await Self.waitUntil {
            store.spendDashboardCodexCostCatchUpTask == nil
        }

        #expect(store.spendDashboardCodexCostCatchUpRetryNotBefore == nil)
        #expect(store.spendDashboardCodexCostCatchUpRetryScopeSignature == nil)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.phase == .complete)
    }

    @Test
    func `dashboard catch-up stalls a cache that revisits an earlier semantic state`() async throws {
        let store = try Self.makeStore(suite: "cyclic-progress")
        let accounts = [Self.account(id: "cyclic", cacheIdentity: "cache-cyclic")]
        let progressKeys = ["validation-1", "validation-2", "validation-0"]
        var advanceCount = 0
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            Self.status(pending: true, key: "validation-0", processedBytes: 25)
        }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { _, _, _ in
            advanceCount += 1
            return Self.status(
                pending: true,
                key: progressKeys[min(advanceCount - 1, progressKeys.count - 1)],
                processedBytes: 25)
        }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { _ in
            await Task.yield()
        }
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = {
            (.ac, false, .nominal)
        }

        store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts, mode: .accelerated)
        await Self.waitUntil {
            store.spendDashboardCodexCostCatchUpTask == nil
        }

        #expect(advanceCount == 3)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.phase == .paused)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.pauseReason == .noProgress)
    }

    @Test
    func `a same-mode dashboard reload queues a worker after the completing task`() async throws {
        let store = try Self.makeStore(suite: "same-mode-restart")
        let accounts = [Self.account(id: "account", cacheIdentity: "cache-account")]
        var statusLoadCount = 0
        var advanceCount = 0
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            statusLoadCount += 1
            return Self.status(
                pending: statusLoadCount == 2,
                key: "status-\(statusLoadCount)",
                processedBytes: statusLoadCount == 2 ? 25 : 100)
        }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { _, _, _ in
            advanceCount += 1
            return Self.status(pending: false, key: "complete", processedBytes: 100)
        }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { _ in
            await Task.yield()
        }
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = {
            (.ac, false, .nominal)
        }

        store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts)
        store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts)
        await Self.waitUntil {
            store.spendDashboardCodexCostCatchUpTask == nil && statusLoadCount == 2
        }

        #expect(statusLoadCount == 2)
        #expect(advanceCount == 1)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.phase == .complete)
    }

    @Test
    func `dashboard synchronization keeps an accelerated account queue accelerated`() throws {
        let store = try Self.makeStore(suite: "preserve-mode")
        let accounts = [Self.account(id: "account", cacheIdentity: "cache-account")]

        store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts, mode: .accelerated)
        let originalToken = store.spendDashboardCodexCostCatchUpToken
        store.synchronizeSpendDashboardCodexCostCatchUp(accounts: accounts)

        #expect(originalToken != nil)
        #expect(store.spendDashboardCodexCostCatchUpToken == originalToken)
        #expect(store.spendDashboardCodexCostCatchUpMode == .accelerated)
        store.cancelSpendDashboardCodexCostCatchUp()
    }

    @Test
    func `stopping an active pass clears a queued restart`() throws {
        let store = try Self.makeStore(suite: "stop-clears-restart")
        store.spendDashboardCodexCostCatchUpTask = Task {}
        store.spendDashboardCodexCostCatchUpPassIsRunning = true
        store.spendDashboardCodexCostCatchUpRestartRequested = true

        store.stopSpendDashboardCodexCostCatchUp()

        #expect(store.spendDashboardCodexCostCatchUpStopRequested)
        #expect(!store.spendDashboardCodexCostCatchUpRestartRequested)
        store.cancelSpendDashboardCodexCostCatchUp()
    }

    @Test
    func `synchronization after an explicit stop does not restart the worker`() throws {
        let store = try Self.makeStore(suite: "stop-stays-durable")
        let accounts = [Self.account(id: "account", cacheIdentity: "cache-account")]
        store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts, mode: .accelerated)
        store.stopSpendDashboardCodexCostCatchUp()

        store.synchronizeSpendDashboardCodexCostCatchUp(accounts: accounts)

        #expect(store.spendDashboardCodexCostCatchUpStopRequested)
        #expect(store.spendDashboardCodexCostCatchUpTask == nil)
        store.cancelSpendDashboardCodexCostCatchUp()
    }

    @Test
    func `visible synchronization upgrades an automatic worker to accelerated`() throws {
        let store = try Self.makeStore(suite: "upgrade-automatic-on-visible")
        let accounts = [Self.account(id: "account", cacheIdentity: "cache-account")]
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = {
            (.ac, false, .nominal)
        }

        store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts, mode: .automatic)
        let originalToken = store.spendDashboardCodexCostCatchUpToken
        store.synchronizeSpendDashboardCodexCostCatchUp(accounts: accounts, preferredMode: .accelerated)

        #expect(originalToken != nil)
        #expect(store.spendDashboardCodexCostCatchUpTask != nil)
        #expect(store.spendDashboardCodexCostCatchUpMode == .accelerated)
        store.cancelSpendDashboardCodexCostCatchUp()
    }

    @Test
    func `visible synchronization does not bypass low power mode`() throws {
        let store = try Self.makeStore(suite: "visible-respects-low-power")
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = {
            (.battery, true, .nominal)
        }

        store.synchronizeSpendDashboardCodexCostCatchUp(
            accounts: [Self.account(id: "account", cacheIdentity: "cache-account")],
            preferredMode: .accelerated)

        #expect(store.spendDashboardCodexCostCatchUpMode == .automatic)
        store.cancelSpendDashboardCodexCostCatchUp()
    }

    @Test
    func `global low power mode floors automatic dashboard wakeups at thirty minutes`() async throws {
        let store = try Self.makeStore(suite: "global-low-power-delay")
        store.settings.backgroundWorkLowPowerModePreference = .on
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            Self.status(pending: true, key: "pending", processedBytes: 25)
        }
        var observedDelay: TimeInterval?
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { delay in
            observedDelay = delay
            throw CancellationError()
        }
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = {
            (.battery, true, .nominal)
        }

        store.startSpendDashboardCodexCostCatchUpIfNeeded(
            accounts: [Self.account(id: "account", cacheIdentity: "cache-account")])
        await Self.waitUntil {
            store.spendDashboardCodexCostCatchUpTask == nil
        }

        #expect(observedDelay == BackgroundWorkPowerPolicy.lowPowerMinimumInterval)
    }

    @Test
    func `global low power mode cancels hidden dashboard catch-up`() throws {
        let store = try Self.makeStore(suite: "global-low-power-hidden")
        let accounts = [Self.account(id: "account", cacheIdentity: "cache-account")]
        store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts, mode: .accelerated)
        #expect(store.spendDashboardCodexCostCatchUpTask != nil)

        store.settings.backgroundWorkLowPowerModePreference = .on
        store.synchronizeSpendDashboardCodexCostCatchUp(accounts: accounts, preferredMode: .automatic)

        #expect(store.spendDashboardCodexCostCatchUpTask == nil)
        #expect(store.spendDashboardCodexCostCatchUpActivity == nil)
    }

    @Test
    func `global low power mode permits explicit visible dashboard catch-up`() throws {
        let store = try Self.makeStore(suite: "global-low-power-visible")
        store.settings.backgroundWorkLowPowerModePreference = .on
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = {
            (.ac, false, .nominal)
        }

        store.synchronizeSpendDashboardCodexCostCatchUp(
            accounts: [Self.account(id: "account", cacheIdentity: "cache-account")],
            preferredMode: .accelerated)

        #expect(store.spendDashboardCodexCostCatchUpTask != nil)
        #expect(store.spendDashboardCodexCostCatchUpMode == .accelerated)
        store.cancelSpendDashboardCodexCostCatchUp()
    }

    @Test
    func `visible synchronization does not bypass serious thermal pressure`() throws {
        let store = try Self.makeStore(suite: "visible-respects-thermal-pressure")
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = {
            (.ac, false, .serious)
        }

        store.synchronizeSpendDashboardCodexCostCatchUp(
            accounts: [Self.account(id: "account", cacheIdentity: "cache-account")],
            preferredMode: .accelerated)

        #expect(store.spendDashboardCodexCostCatchUpMode == .automatic)
        store.cancelSpendDashboardCodexCostCatchUp()
    }

    @Test
    func `visible synchronization preserves an explicitly accelerated worker in low power mode`() throws {
        let store = try Self.makeStore(suite: "explicit-acceleration-in-low-power")
        let accounts = [Self.account(id: "account", cacheIdentity: "cache-account")]
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = {
            (.battery, true, .serious)
        }
        store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts, mode: .accelerated)

        store.synchronizeSpendDashboardCodexCostCatchUp(accounts: accounts, preferredMode: .accelerated)

        #expect(store.spendDashboardCodexCostCatchUpMode == .accelerated)
        store.cancelSpendDashboardCodexCostCatchUp()
    }

    @Test
    func `hidden synchronization downgrades an accelerated worker to automatic`() throws {
        let store = try Self.makeStore(suite: "downgrade-accelerated-on-hidden")
        let accounts = [Self.account(id: "account", cacheIdentity: "cache-account")]

        store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts, mode: .accelerated)
        store.synchronizeSpendDashboardCodexCostCatchUp(accounts: accounts, preferredMode: .automatic)

        #expect(store.spendDashboardCodexCostCatchUpTask != nil)
        #expect(store.spendDashboardCodexCostCatchUpMode == .automatic)
        store.cancelSpendDashboardCodexCostCatchUp()
    }

    @Test
    func `stopped synchronization still clears an invalid account scope`() throws {
        let store = try Self.makeStore(suite: "stopped-invalid-account-scope")
        let accounts = [Self.account(id: "account", cacheIdentity: "cache-account")]
        store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts, mode: .accelerated)
        store.stopSpendDashboardCodexCostCatchUp()

        store.synchronizeSpendDashboardCodexCostCatchUp(accounts: [])

        #expect(store.spendDashboardCodexCostCatchUpTask == nil)
        #expect(!store.spendDashboardCodexCostCatchUpStopRequested)
    }

    private static func makeStore(suite: String) throws -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "UsageStoreSpendDashboardCodexCostCatchUpTests-\(suite)")
        settings.costUsageEnabled = true
        let metadata = try #require(ProviderRegistry.shared.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: metadata, enabled: true)
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }

    private static func receivedHistoryDays(
        configuredHistoryDays: Int,
        suite: String) async throws -> Int
    {
        let store = try Self.makeStore(suite: suite)
        let account = Self.account(id: "account", cacheIdentity: "cache-account")
        store.settings.costUsageHistoryDays = configuredHistoryDays
        var completed = false
        var receivedHistoryDays: Int?
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            Self.status(
                pending: !completed,
                key: completed ? "complete" : "pending",
                processedBytes: completed ? 100 : 25)
        }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { _, _, historyDays in
            receivedHistoryDays = historyDays
            completed = true
            return Self.status(pending: false, key: "complete", processedBytes: 100)
        }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { _ in
            await Task.yield()
        }
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = {
            (.battery, true, .serious)
        }

        store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: [account], mode: .accelerated)
        await Self.waitUntil {
            store.spendDashboardCodexCostCatchUpTask == nil
        }

        return try #require(receivedHistoryDays)
    }

    private static func account(id: String, cacheIdentity: String) -> CodexSpendScanRequest {
        CodexSpendScanRequest(
            id: id,
            displayName: "Codex · \(id)",
            source: .profileHome(path: "/synthetic/\(id)"),
            homePath: "/synthetic/\(id)",
            authFingerprint: nil,
            authFileWasReadable: false,
            cacheIdentity: cacheIdentity)
    }

    private static func status(
        pending: Bool,
        key: String,
        processedBytes: Int64) -> CostUsageFetcher.CodexScanCatchUpStatus
    {
        CostUsageFetcher.CodexScanCatchUpStatus(
            pending: pending,
            progressKey: key,
            processedBytes: processedBytes,
            totalBytes: 100,
            completedFiles: pending ? 0 : 1,
            totalFiles: 1)
    }

    private static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<1000 {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("Timed out waiting for Spend Dashboard Codex cost catch-up")
    }
}
