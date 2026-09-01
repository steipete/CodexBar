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

    @Test(arguments: [false, true])
    func `terminal pauses survive synchronization until explicit refresh`(throwsError: Bool) async throws {
        let store = try Self.makeStore(suite: "terminal-resume-\(throwsError)")
        defer { store.cancelSpendDashboardCodexCostCatchUp() }
        let accounts = [Self.account(id: "account", cacheIdentity: "cache-account")]
        var advanceCount = 0
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            Self.status(pending: true, key: "unchanged", processedBytes: 25)
        }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { _, _, _ in
            advanceCount += 1
            if throwsError, advanceCount == 1 {
                throw NSError(domain: "SyntheticCatchUp", code: 1)
            }
            return Self.status(
                pending: advanceCount == 1,
                key: advanceCount == 1 ? "unchanged" : "complete",
                processedBytes: advanceCount == 1 ? 25 : 100)
        }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { _ in await Task.yield() }
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }

        store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts, mode: .accelerated)
        await Self.waitUntil { store.spendDashboardCodexCostCatchUpTask == nil }
        let pausedActivity = try #require(store.spendDashboardCodexCostCatchUpActivity)
        #expect(pausedActivity.phase == .paused)
        #expect(advanceCount == 1)

        store.synchronizeSpendDashboardCodexCostCatchUp(accounts: accounts)
        store.synchronizeSpendDashboardCodexCostCatchUp(accounts: accounts, preferredMode: .accelerated)
        store.synchronizeSpendDashboardCodexCostCatchUp(accounts: accounts, preferredMode: .automatic)

        try #require(store.spendDashboardCodexCostCatchUpTask == nil)
        #expect(store.spendDashboardCodexCostCatchUpActivity == pausedActivity)
        #expect(advanceCount == 1)
        #expect(!store.spendDashboardCodexCostCatchUpRestartRequested)

        store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts, mode: .automatic)
        await Self.waitUntil { store.spendDashboardCodexCostCatchUpTask == nil }
        #expect(advanceCount == 2)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.phase == .complete)
    }

    @Test(arguments: [CodexCostCatchUpPauseReason.user, .noProgress, .error("Synthetic failure")])
    func `dashboard toolbar refresh explicitly resumes terminal catch-up pauses`(
        reason: CodexCostCatchUpPauseReason) async throws
    {
        let store = try Self.makeStore(suite: "toolbar-resume-\(reason)")
        defer { store.stopSharedSpendDashboardPublication() }
        let accounts = [Self.account(id: "account", cacheIdentity: "cache-account")]
        let configuration = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.codex.rawValue],
            codexAccountIdentities: ["account|cache-account"])
        var requestedModes: [SpendDashboardRequestBuildMode] = []
        let controller = SpendDashboardController(
            requestBuilder: { mode in
                requestedModes.append(mode)
                return SpendDashboardLoadRequest(
                    configuration: configuration,
                    capturedInputs: [],
                    unavailableSourceIDs: [],
                    codexRequests: [],
                    now: Date(),
                    force: mode.forcesLoader)
            },
            loader: { _ in .init(inputs: [], failedSourceIDs: []) })
        store.sharedSpendDashboardControllerStorage = controller
        controller.update(configuration: configuration)
        await Self.waitUntil { !controller.isRefreshing }
        requestedModes.removeAll()
        store.spendDashboardCodexCostCatchUpActivity = Self.pausedActivity(reason: reason)
        store.spendDashboardCodexCostCatchUpStopRequested = reason == .user
        var statusAccounts: [String] = []
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { account in
            statusAccounts.append(account.id)
            return Self.status(pending: false, key: "complete", processedBytes: 100)
        }

        store.refreshSpendDashboard(accounts: accounts)

        try #require(store.spendDashboardCodexCostCatchUpTask != nil)
        #expect(!store.spendDashboardCodexCostCatchUpStopRequested)
        await Self.waitUntil { store.spendDashboardCodexCostCatchUpTask == nil && !controller.isRefreshing }
        #expect(store.spendDashboardCodexCostCatchUpActivity?.phase == .complete)
        #expect(requestedModes.count(where: { $0 == .forceRefresh }) == 1)
        #expect(statusAccounts == ["account"])
    }

    @Test
    func `dashboard toolbar refresh does not change an active catch-up worker`() throws {
        let store = try Self.makeStore(suite: "toolbar-active-worker")
        defer { store.stopSharedSpendDashboardPublication() }
        let accounts = [Self.account(id: "account", cacheIdentity: "cache-account")]
        store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts, mode: .accelerated)
        let token = try #require(store.spendDashboardCodexCostCatchUpToken)

        store.refreshSpendDashboard(accounts: accounts)

        #expect(store.spendDashboardCodexCostCatchUpToken == token)
        #expect(store.spendDashboardCodexCostCatchUpMode == .accelerated)
        #expect(!store.spendDashboardCodexCostCatchUpRestartRequested)
    }

    @Test(arguments: [false, true])
    func `terminal pauses discard a synchronization queued during the pass`(throwsError: Bool) async throws {
        let store = try Self.makeStore(suite: "terminal-queued-restart-\(throwsError)")
        defer { store.cancelSpendDashboardCodexCostCatchUp() }
        let accounts = [Self.account(id: "account", cacheIdentity: "cache-account")]
        var statusLoadCount = 0
        var advanceCount = 0
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            statusLoadCount += 1
            return Self.status(pending: true, key: "unchanged", processedBytes: 25)
        }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { [weak store] _, _, _ in
            advanceCount += 1
            if advanceCount == 1 {
                store?.synchronizeSpendDashboardCodexCostCatchUp(accounts: accounts)
                #expect(store?.spendDashboardCodexCostCatchUpRestartRequested == true)
            }
            if throwsError {
                throw NSError(domain: "SyntheticCatchUp", code: 1)
            }
            return Self.status(pending: true, key: "unchanged", processedBytes: 25)
        }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { _ in await Task.yield() }
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }

        store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts, mode: .accelerated)
        await Self.waitUntil { store.spendDashboardCodexCostCatchUpTask == nil }

        #expect(statusLoadCount == 1)
        #expect(advanceCount == 1)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.phase == .paused)
        #expect(!store.spendDashboardCodexCostCatchUpRestartRequested)
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

    @Test(arguments: [CodexCostCatchUpPauseReason.noProgress, .error("Synthetic failure")])
    func `terminal synchronization still clears invalid scopes`(reason: CodexCostCatchUpPauseReason) throws {
        let store = try Self.makeStore(suite: "terminal-invalid-scope-\(reason)")
        let accounts = [Self.account(id: "account", cacheIdentity: "cache-account")]
        let activity = Self.pausedActivity(reason: reason)

        store.spendDashboardCodexCostCatchUpActivity = activity
        store.synchronizeSpendDashboardCodexCostCatchUp(accounts: [])
        #expect(store.spendDashboardCodexCostCatchUpActivity == nil)

        store.spendDashboardCodexCostCatchUpActivity = activity
        store.settings.costUsageEnabled = false
        store.synchronizeSpendDashboardCodexCostCatchUp(accounts: accounts)
        #expect(store.spendDashboardCodexCostCatchUpActivity == nil)

        store.settings.costUsageEnabled = true
        let metadata = try #require(ProviderRegistry.shared.metadata[.codex])
        store.settings.setProviderEnabled(provider: .codex, metadata: metadata, enabled: false)
        store.spendDashboardCodexCostCatchUpActivity = activity
        store.synchronizeSpendDashboardCodexCostCatchUp(accounts: accounts)
        #expect(store.spendDashboardCodexCostCatchUpActivity == nil)
        #expect(store.spendDashboardCodexCostCatchUpTask == nil)
    }

    @Test(arguments: [CodexCostCatchUpPauseReason.lowPower, .thermal])
    func `resource pauses still allow synchronization`(reason: CodexCostCatchUpPauseReason) throws {
        let store = try Self.makeStore(suite: "resource-resume-\(reason)")
        defer { store.cancelSpendDashboardCodexCostCatchUp() }
        store.spendDashboardCodexCostCatchUpActivity = Self.pausedActivity(reason: reason)
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            Self.status(pending: false, key: "complete", processedBytes: 100)
        }

        store.synchronizeSpendDashboardCodexCostCatchUp(
            accounts: [Self.account(id: "account", cacheIdentity: "cache-account")])

        #expect(store.spendDashboardCodexCostCatchUpTask != nil)
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

    @Test(arguments: [false, true])
    func `superseded pass completion cannot clear the replacement pass ownership`(
        cancelled: Bool) async throws
    {
        let store = try Self.makeStore(suite: "superseded-pass-\(cancelled)")
        let oldGate = SpendDashboardPendingLoads<CostUsageFetcher.CodexScanCatchUpStatus>()
        let replacementGate = SpendDashboardPendingLoads<CostUsageFetcher.CodexScanCatchUpStatus>()
        defer {
            store.cancelSpendDashboardCodexCostCatchUp()
            oldGate.close()
            replacementGate.close()
        }
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            Self.status(pending: true, key: "pending", processedBytes: 25)
        }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { account, _, _ in
            if account.id == "old" {
                let result = try await oldGate.load()
                if cancelled { throw CancellationError() }
                return result
            }
            return try await replacementGate.load()
        }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { _ in await Task.yield() }
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }

        store.startSpendDashboardCodexCostCatchUpIfNeeded(
            accounts: [Self.account(id: "old", cacheIdentity: "cache-old")], mode: .accelerated)
        let oldTask = try #require(store.spendDashboardCodexCostCatchUpTask)
        try await oldGate.waitForPendingCount(1)
        store.startSpendDashboardCodexCostCatchUpIfNeeded(
            accounts: [Self.account(id: "replacement", cacheIdentity: "cache-replacement")], mode: .accelerated)
        let replacementTask = try #require(store.spendDashboardCodexCostCatchUpTask)
        let replacementToken = try #require(store.spendDashboardCodexCostCatchUpToken)
        try await replacementGate.waitForPendingCount(1)
        #expect(store.spendDashboardCodexCostCatchUpPassIsRunning)

        oldGate.resume(returning: Self.status(pending: false, key: "old-complete", processedBytes: 100))
        await oldTask.value

        #expect(store.spendDashboardCodexCostCatchUpToken == replacementToken)
        #expect(store.spendDashboardCodexCostCatchUpPassIsRunning)
        store.stopSpendDashboardCodexCostCatchUp()
        #expect(store.spendDashboardCodexCostCatchUpTask != nil)
        #expect(store.spendDashboardCodexCostCatchUpToken == replacementToken)
        replacementGate.resume(returning: Self.status(pending: false, key: "complete", processedBytes: 100))
        await replacementTask.value
        #expect(store.spendDashboardCodexCostCatchUpTask == nil)
        #expect(!store.spendDashboardCodexCostCatchUpPassIsRunning)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.pauseReason == .user)
    }

    @Test
    func `an error completed before replacement cannot publish the obsolete revision`() async throws {
        let store = try Self.makeStore(suite: "superseded-error-revision")
        let oldGate = SpendDashboardPendingLoads<Result<CostUsageFetcher.CodexScanCatchUpStatus, any Error>>()
        let replacementGate = SpendDashboardPendingLoads<CostUsageFetcher.CodexScanCatchUpStatus>()
        defer {
            store.cancelSpendDashboardCodexCostCatchUp()
            oldGate.close()
            replacementGate.close()
        }
        var oldAdvanceCount = 0
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            Self.status(pending: true, key: "pending", processedBytes: 25)
        }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { account, _, _ in
            guard account.id == "old" else { return try await replacementGate.load() }
            oldAdvanceCount += 1
            if oldAdvanceCount == 1 {
                return Self.status(pending: true, key: "progress", processedBytes: 50)
            }
            return try await oldGate.load().get()
        }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { _ in await Task.yield() }
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }

        store.startSpendDashboardCodexCostCatchUpIfNeeded(
            accounts: [Self.account(id: "old", cacheIdentity: "cache-old")], mode: .accelerated)
        let oldTask = try #require(store.spendDashboardCodexCostCatchUpTask)
        try await oldGate.waitForPendingCount(1)
        #expect(oldAdvanceCount == 2)
        let revision = store.spendDashboardCodexCostCatchUpRevision
        // The executor can finish before cancellation while its MainActor continuation is still queued.
        oldGate.resume(returning: .failure(NSError(domain: "SyntheticCatchUp", code: 2)))
        store.startSpendDashboardCodexCostCatchUpIfNeeded(
            accounts: [Self.account(id: "replacement", cacheIdentity: "cache-replacement")], mode: .accelerated)
        let replacementTask = try #require(store.spendDashboardCodexCostCatchUpTask)
        let replacementToken = try #require(store.spendDashboardCodexCostCatchUpToken)
        await oldTask.value
        try await replacementGate.waitForPendingCount(1)

        #expect(store.spendDashboardCodexCostCatchUpRevision == revision)
        #expect(store.spendDashboardCodexCostCatchUpToken == replacementToken)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.pauseReason == nil)
        #expect(store.spendDashboardCodexCostCatchUpPassIsRunning)
        replacementGate.resume(returning: Self.status(pending: false, key: "complete", processedBytes: 100))
        await replacementTask.value
        #expect(store.spendDashboardCodexCostCatchUpRevision == revision + 1)
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

    private static func pausedActivity(reason: CodexCostCatchUpPauseReason) -> CodexCostCatchUpActivity {
        CodexCostCatchUpActivity(
            phase: .paused,
            mode: .automatic,
            processedBytes: 25,
            totalBytes: 100,
            completedFiles: 0,
            totalFiles: 1,
            pauseReason: reason,
            staleSnapshotUpdatedAt: nil)
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
