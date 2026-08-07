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

        #expect(advancedAccounts == ["stalled", "healthy", "stalled"])
        #expect(store.spendDashboardCodexCostCatchUpRevision == 1)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.phase == .paused)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.pauseReason == .noProgress)
    }

    @Test
    func `each pending dashboard account gets one turn per sweep`() async throws {
        let store = try Self.makeStore(suite: "round-robin-sweeps")
        let accounts = [
            Self.account(id: "first", cacheIdentity: "cache-first"),
            Self.account(id: "second", cacheIdentity: "cache-second"),
        ]
        var passCounts: [String: Int] = [:]
        var advancedAccounts: [String] = []
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { account in
            Self.status(pending: true, key: "pending-\(account.id)-0", processedBytes: 0)
        }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { account, _, _ in
            advancedAccounts.append(account.id)
            passCounts[account.id, default: 0] += 1
            let pass = passCounts[account.id, default: 0]
            return Self.status(
                pending: pass < 3,
                key: "progress-\(account.id)-\(pass)",
                processedBytes: Int64(pass * 25))
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

        #expect(advancedAccounts == ["first", "second", "first", "second", "first", "second"])
        #expect(store.spendDashboardCodexCostCatchUpActivity?.phase == .complete)
    }

    @Test
    func `a no-progress pass does not publish a reload revision`() async throws {
        let store = try Self.makeStore(suite: "no-progress-revision")
        let accounts = [Self.account(id: "stalled", cacheIdentity: "cache-stalled")]
        var advanceCount = 0
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            Self.status(pending: true, key: "unchanged", processedBytes: 25)
        }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { _, _, _ in
            advanceCount += 1
            return Self.status(pending: true, key: "unchanged", processedBytes: 25)
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

        #expect(advanceCount == 2)
        #expect(store.spendDashboardCodexCostCatchUpRevision == 0)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.phase == .paused)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.pauseReason == .noProgress)
    }

    @Test
    func `dashboard retries a concurrent writer whose old cache looks complete`() async throws {
        let store = try Self.makeStore(suite: "concurrent-writer")
        let account = Self.account(id: "contended", cacheIdentity: "cache-contended")
        var advanceCount = 0
        var sleepDurations: [TimeInterval] = []
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            Self.status(
                pending: false,
                key: advanceCount < 2 ? "published-before-owner" : "complete",
                processedBytes: advanceCount < 2 ? 25 : 100,
                deferredByConcurrentWriter: advanceCount < 2)
        }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { _, _, _ in
            advanceCount += 1
            if advanceCount == 1 {
                return Self.status(
                    pending: false,
                    key: "published-before-owner",
                    processedBytes: 25,
                    deferredByConcurrentWriter: true)
            }
            return Self.status(pending: false, key: "complete", processedBytes: 100)
        }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { duration in
            sleepDurations.append(duration)
            await Task.yield()
        }
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = {
            (.ac, false, .nominal)
        }

        store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: [account], mode: .accelerated)
        await Self.waitUntil {
            store.spendDashboardCodexCostCatchUpTask == nil
        }

        #expect(advanceCount == 2)
        #expect(sleepDurations.contains(1))
        #expect(store.spendDashboardCodexCostCatchUpActivity?.phase == .complete)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.pauseReason == nil)
    }

    @Test
    func `dashboard contention does not starve a sibling account`() async throws {
        let store = try Self.makeStore(suite: "contended-sibling")
        let accounts = [
            Self.account(id: "contended", cacheIdentity: "cache-contended"),
            Self.account(id: "healthy", cacheIdentity: "cache-healthy"),
        ]
        var contendedAdvanceCount = 0
        var healthyIsComplete = false
        var advancedAccounts: [String] = []
        var sleepDurations: [TimeInterval] = []
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { account in
            if account.id == "healthy", healthyIsComplete {
                return Self.status(pending: false, key: "healthy-complete", processedBytes: 100)
            }
            return Self.status(pending: true, key: "pending-\(account.id)", processedBytes: 25)
        }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { account, _, _ in
            advancedAccounts.append(account.id)
            if account.id == "healthy" {
                healthyIsComplete = true
                return Self.status(pending: false, key: "healthy-complete", processedBytes: 100)
            }
            contendedAdvanceCount += 1
            if contendedAdvanceCount <= 2 {
                return Self.status(
                    pending: false,
                    key: "pending-contended",
                    processedBytes: 25,
                    deferredByConcurrentWriter: true)
            }
            return Self.status(pending: false, key: "contended-complete", processedBytes: 100)
        }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { duration in
            sleepDurations.append(duration)
            await Task.yield()
        }
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = {
            (.ac, false, .nominal)
        }

        store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts, mode: .accelerated)
        await Self.waitUntil {
            store.spendDashboardCodexCostCatchUpTask == nil
        }

        #expect(advancedAccounts == ["contended", "healthy", "contended", "contended"])
        #expect(sleepDurations.count(where: { $0 == 1 }) == 2)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.phase == .complete)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.pauseReason == nil)
    }

    @Test
    func `dashboard repeated unavailable refresh lock pauses with an error`() async throws {
        let store = try Self.makeStore(suite: "unavailable-refresh-lock")
        let account = Self.account(id: "unavailable", cacheIdentity: "cache-unavailable")
        var advanceCount = 0
        var sleepDurations: [TimeInterval] = []
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            Self.status(pending: true, key: "unavailable", processedBytes: 25)
        }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { _, _, _ in
            advanceCount += 1
            return Self.status(
                pending: false,
                key: "unavailable",
                processedBytes: 25,
                refreshLockUnavailable: true)
        }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { duration in
            sleepDurations.append(duration)
            await Task.yield()
        }
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = {
            (.ac, false, .nominal)
        }

        store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: [account], mode: .accelerated)
        await Self.waitUntil {
            store.spendDashboardCodexCostCatchUpTask == nil
        }

        #expect(advanceCount == 2)
        #expect(sleepDurations.count(where: { $0 == 1 }) == 1)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.phase == .paused)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.pauseReason == .error(
            CostUsageFetcher.CodexScanCatchUpStatus.refreshLockUnavailableErrorMessage))
    }

    @Test
    func `dashboard unavailable refresh lock does not starve a sibling account`() async throws {
        let store = try Self.makeStore(suite: "unavailable-refresh-lock-sibling")
        let accounts = [
            Self.account(id: "unavailable", cacheIdentity: "cache-unavailable"),
            Self.account(id: "healthy", cacheIdentity: "cache-healthy"),
        ]
        var healthyAdvanceCount = 0
        var advancedAccounts: [String] = []
        var sleepDurations: [TimeInterval] = []
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { account in
            Self.status(
                pending: true,
                key: "pending-\(account.id)",
                processedBytes: 25)
        }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { account, _, _ in
            advancedAccounts.append(account.id)
            if account.id == "unavailable" {
                return Self.status(
                    pending: false,
                    key: "unavailable",
                    processedBytes: 25,
                    refreshLockUnavailable: true)
            }

            healthyAdvanceCount += 1
            return Self.status(
                pending: healthyAdvanceCount < 3,
                key: "healthy-\(healthyAdvanceCount)",
                processedBytes: Int64(healthyAdvanceCount * 25))
        }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { duration in
            sleepDurations.append(duration)
            await Task.yield()
        }
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = {
            (.ac, false, .nominal)
        }

        store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts, mode: .accelerated)
        await Self.waitUntil {
            store.spendDashboardCodexCostCatchUpTask == nil
        }

        #expect(advancedAccounts == ["unavailable", "healthy", "unavailable", "healthy", "healthy"])
        #expect(healthyAdvanceCount == 3)
        #expect(sleepDurations.count(where: { $0 == 1 }) == 1)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.phase == .paused)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.pauseReason == .error(
            CostUsageFetcher.CodexScanCatchUpStatus.refreshLockUnavailableErrorMessage))
    }

    @Test
    func `dashboard transient unchanged pass backs off and can recover`() async throws {
        let store = try Self.makeStore(suite: "transient-no-progress")
        let account = Self.account(id: "transient", cacheIdentity: "cache-transient")
        var advanceCount = 0
        var sleepDurations: [TimeInterval] = []
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            Self.status(
                pending: advanceCount < 2,
                key: advanceCount < 2 ? "unchanged" : "complete",
                processedBytes: advanceCount < 2 ? 25 : 100)
        }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { _, _, _ in
            advanceCount += 1
            return Self.status(
                pending: advanceCount < 2,
                key: advanceCount < 2 ? "unchanged" : "complete",
                processedBytes: advanceCount < 2 ? 25 : 100)
        }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { duration in
            sleepDurations.append(duration)
            await Task.yield()
        }
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = {
            (.ac, false, .nominal)
        }

        store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: [account], mode: .accelerated)
        await Self.waitUntil {
            store.spendDashboardCodexCostCatchUpTask == nil
        }

        #expect(advanceCount == 2)
        #expect(sleepDurations.contains(1))
        #expect(store.spendDashboardCodexCostCatchUpActivity?.phase == .complete)
        #expect(store.spendDashboardCodexCostCatchUpActivity?.pauseReason == nil)
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
        processedBytes: Int64,
        deferredByConcurrentWriter: Bool = false,
        refreshLockUnavailable: Bool = false) -> CostUsageFetcher.CodexScanCatchUpStatus
    {
        CostUsageFetcher.CodexScanCatchUpStatus(
            pending: pending,
            progressKey: key,
            processedBytes: processedBytes,
            totalBytes: 100,
            completedFiles: pending ? 0 : 1,
            totalFiles: 1,
            deferredByConcurrentWriter: deferredByConcurrentWriter,
            refreshLockUnavailable: refreshLockUnavailable)
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
