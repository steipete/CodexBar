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
