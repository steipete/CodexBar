import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct CopilotAllowanceCacheTests {
    @Test(arguments: [false, true], [false, true])
    func `delayed successful refresh respects current global and account allowances`(
        clear: Bool,
        accountOverride: Bool) async throws
    {
        let fixture = CopilotAllowanceFixture()
        defer { fixture.stop() }
        fixture.settings.copilotSeatCreditEntitlementRaw = "3000"
        try fixture.seedAccounts()
        fixture.store.setCopilotSeatCreditEntitlement(accountOverride ? "5000" : "")
        let old = try #require(fixture.store.snapshots[.copilot])
        let fetched = UsageSnapshot(
            primary: nil,
            secondary: nil,
            details: old.details,
            updatedAt: old.updatedAt.addingTimeInterval(60))
        let gate = CopilotAllowanceResponseGate()
        fixture.store._test_providerFetchOutcomeOverride = { _ in
            await gate.wait()
            return ProviderFetchOutcome(
                result: .success(ProviderFetchResult(
                    usage: fetched,
                    credits: nil,
                    dashboard: nil,
                    sourceLabel: "fixture",
                    strategyID: "fixture",
                    strategyKind: .web)),
                attempts: [])
        }
        let refresh = Task { await fixture.store.refreshProvider(.copilot, allowDisabled: true) }
        while !gate.started {
            await Task.yield()
        }
        if accountOverride {
            fixture.store.setCopilotSeatCreditEntitlement(clear ? "" : "7000")
        } else if clear {
            fixture.store.clearCopilotDefaultSeatCreditEntitlement()
        } else {
            fixture.settings.copilotSeatCreditEntitlementRaw = "7000"
            fixture.store.updateCopilotSeatCreditEntitlement(7000)
        }
        gate.resume()
        await refresh.value
        fixture.store._test_providerFetchOutcomeOverride = { _ in
            ProviderFetchOutcome(result: .failure(URLError(.notConnectedToInternet)), attempts: [])
        }
        await fixture.store.refreshProvider(.copilot, allowDisabled: true)
        let cache = try #require(fixture.store.validTokenAccountSnapshots(
            provider: .copilot, accounts: fixture.settings.tokenAccounts(for: .copilot)).first)
        for snapshot in [
            fixture.store.snapshots[.copilot],
            fixture.store.lastKnownResetSnapshots[.copilot],
            cache.snapshot,
        ] {
            let snapshot = try #require(snapshot)
            let row = try #require(snapshot.details.flatMap(\.rows).first)
            let expectedTotal: Double? = clear ? (accountOverride ? 3000 : nil) : 7000
            #expect(row.progress?.total == expectedTotal)
            #expect(row.usageValue == 123)
            #expect(snapshot.updatedAt == (accountOverride ? old.updatedAt : fetched.updatedAt))
        }
    }

    @Test(arguments: [false, true])
    func `clear default action updates inheriting accounts while preserving overrides`(hasOverride: Bool) async throws {
        let fixture = CopilotAllowanceFixture()
        defer { fixture.stop() }
        fixture.settings.copilotSeatCreditEntitlementRaw = "3000"
        try fixture.seedAccounts()
        let field = try #require(fixture.field)
        field.binding.wrappedValue = hasOverride ? "5000" : ""
        fixture.settings.setActiveTokenAccountIndex(1, for: .copilot)
        fixture.reconcile()
        field.binding.wrappedValue = ""
        fixture.settings.setActiveTokenAccountIndex(0, for: .copilot)
        fixture.reconcile()
        let updatedAt = fixture.store.snapshots[.copilot]?.updatedAt
        let action = try #require(field.actions.first { $0.id == "copilot-clear-default-allowance" })
        #expect(action.isVisible?() == true)
        await action.perform()
        await fixture.store.refreshProvider(.copilot, allowDisabled: true)
        #expect(fixture.settings.copilotSeatCreditEntitlementRaw.isEmpty)
        #expect(action.isVisible?() == false)
        #expect(fixture.row?.progress?.total == (hasOverride ? 5000 : nil))
        #expect(fixture.row?.usageValue == 123)
        #expect(fixture.store.snapshots[.copilot]?.updatedAt == updatedAt)
        fixture.settings.setActiveTokenAccountIndex(1, for: .copilot)
        fixture.reconcile()
        #expect(fixture.row?.progress == nil)
        #expect(fixture.row?.usageValue == 456)
    }

    @Test
    func `allowance binding preserves cached usage through offline edits and account switches`() async throws {
        let fixture = CopilotAllowanceFixture()
        defer { fixture.stop() }
        fixture.settings.copilotSeatCreditEntitlementRaw = "3000"
        try fixture.seedAccounts()
        let field = try #require(fixture.field)
        let original = try #require(fixture.store.snapshots[.copilot])
        for (raw, total) in [("5000", 5000.0), ("", 3000.0), ("7000", 7000.0)] {
            let previousError = fixture.store.accountSnapshots[.copilot]?.first?.error
            let previousFailures = fixture.failedRefreshes
            field.binding.wrappedValue = raw
            #expect(fixture.store.errors[.copilot] == previousError)
            fixture.reconcile()
            await fixture.store.refreshProvider(
                .copilot,
                allowDisabled: true)
            let row = try #require(fixture.row)
            #expect(row.progress?.total == total)
            #expect(row.usageValue == 123)
            #expect(fixture.store.snapshots[.copilot]?.updatedAt == original.updatedAt)
            #expect(fixture.store.lastKnownResetSnapshots[.copilot]?.updatedAt == original.updatedAt)
            #expect(fixture.failedRefreshes == previousFailures + 1)
            #expect(fixture.store.accountSnapshots[.copilot]?.first?.error == previousError)
            let expectedVisibleError = previousFailures == 0 ? nil : URLError(.notConnectedToInternet)
                .localizedDescription
            #expect(fixture.store.errors[.copilot] == expectedVisibleError)
            #expect(fixture.store.lastSourceLabels[.copilot] == "fixture")
        }
        fixture.settings.setActiveTokenAccountIndex(
            1,
            for: .copilot)
        fixture.reconcile()
        #expect(fixture.row?.usageValue == 456)
        #expect(fixture.row?.progress?.total == 9000)
        fixture.settings.setActiveTokenAccountIndex(
            0,
            for: .copilot)
        fixture.reconcile()
        #expect(fixture.row?.usageValue == 123)
        #expect(fixture.row?.progress?.total == 7000)
        fixture.settings.copilotSeatCreditEntitlementRaw = ""
        field.binding.wrappedValue = ""
        fixture.reconcile()
        #expect(fixture.row?.progress == nil)
        #expect(fixture.row?.usageValue == 123)
    }

    @Test
    func `global allowance edits preserve the independent reset baseline`() throws {
        let fixture = CopilotAllowanceFixture()
        defer { fixture.stop() }
        try fixture.seedAccounts()
        let accounts = fixture.settings.tokenAccounts(for: .copilot)
        let live = try #require(fixture.store.accountSnapshots[.copilot]?.first?.snapshot)
        let baseline = try #require(fixture.store.accountSnapshots[.copilot]?.last?.snapshot)
        for account in accounts {
            fixture.settings.removeTokenAccount(
                provider: .copilot,
                accountID: account.id)
        }
        fixture.store.snapshots[.copilot] = live
        fixture.store.lastKnownResetSnapshots[.copilot] = baseline
        fixture.store.setCopilotSeatCreditEntitlement("5000")
        #expect(fixture.row?.usageValue == 123)
        let resetRow = fixture.store.lastKnownResetSnapshots[.copilot]?.details.flatMap(\.rows).first
        #expect(resetRow?.usageValue == 456)
        #expect(resetRow?.progress?.total == 5000)
        #expect(fixture.store.lastKnownResetSnapshots[.copilot]?.updatedAt == baseline.updatedAt)
    }

    @Test(arguments: [true, false])
    func `allowance edit never revives a cache after credential or endpoint changes`(credential: Bool) async throws {
        let fixture = CopilotAllowanceFixture()
        defer { fixture.stop() }
        try fixture.seedAccounts()
        let account = try #require(fixture.settings.effectiveSelectedTokenAccount(for: .copilot))
        if credential {
            fixture.settings.updateTokenAccount(
                provider: .copilot,
                accountID: account.id,
                token: "changed-fixture-token")
        } else {
            fixture.settings.copilotEnterpriseHost = "example.ghe.com"
        }
        let field = try #require(fixture.field)
        field.binding.wrappedValue = "5000"
        fixture.reconcile()
        await fixture.store.refreshProvider(
            .copilot,
            allowDisabled: true)
        #expect(fixture.store.snapshots[.copilot] == nil)
        #expect(fixture.store.lastKnownResetSnapshots[.copilot] == nil)
        #expect(fixture.store.accountSnapshots[.copilot]?.contains { $0.id == account.id } != true)
    }
}

@MainActor
final class CopilotAllowanceResponseGate {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.started = true
        }
    }

    func resume() {
        self.continuation?.resume()
        self.continuation = nil
    }
}

@MainActor
final class CopilotAllowanceFixture {
    let settings: SettingsStore
    let store: UsageStore
    var failedRefreshes = 0

    init() {
        self.settings = testSettingsStore(
            suiteName: "CopilotAllowanceFixture",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled())
        self.store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: self.settings,
            startupBehavior: .testing,
            environmentBase: [:])
        self.settings.statusChecksEnabled = false
        self.settings.multiAccountMenuLayout = .segmented
        self.store._test_providerFetchOutcomeOverride = { [weak self] _ in
            self?.failedRefreshes += 1
            return ProviderFetchOutcome(
                result: .failure(URLError(.notConnectedToInternet)),
                attempts: [])
        }
        self.settings.setProviderEnabled(
            provider: .copilot,
            metadata: ProviderDescriptorRegistry.descriptor(for: .copilot).metadata,
            enabled: true)
    }

    var field: ProviderSettingsFieldDescriptor? {
        let settings = self.settings
        let context = ProviderSettingsContext(
            provider: .copilot,
            settings: settings,
            store: self.store,
            statusText: { _ in nil },
            setStatusText: { _, _ in },
            lastAppActiveRunAt: { _ in nil },
            setLastAppActiveRunAt: { _, _ in },
            requestConfirmation: { _ in },
            runLoginFlow: {})
        return CopilotProviderImplementation().settingsFields(context: context)
            .first { $0.id == "copilot-seat-credit-entitlement" }
    }

    var row: ProviderDetailSection.Row? {
        self.store.snapshots[.copilot]?.details.flatMap(\.rows).first { $0.id == CopilotCreditDetailRows.seatRowID }
    }

    func seedAccounts() throws {
        for (index, used) in [123.0, 456.0].enumerated() {
            self.settings.addTokenAccount(
                provider: .copilot,
                label: "Synthetic \(index + 1)",
                token: "fixture-\(index)")
            self.settings.copilotEffectiveSeatCreditEntitlementRaw = index == 0 ? "3000" : "9000"
            let account = try #require(self.settings.effectiveSelectedTokenAccount(for: .copilot))
            let total = index == 0 ? 3000.0 : 9000.0
            let row = try ProviderDetailSection.Row(
                id: CopilotCreditDetailRows.seatRowID,
                label: "Credits used",
                value: "\(Int(used)) / \(Int(total))",
                progress: ProviderDetailSection.Row.Progress(
                    used: used,
                    total: total),
                usageValue: used)
            let snapshot = try UsageSnapshot(
                primary: nil,
                secondary: nil,
                details: [ProviderDetailSection(
                    title: CopilotCreditDetailRows.sectionTitle,
                    rows: [row])],
                updatedAt: Date(timeIntervalSince1970: 1_789_142_400))
            self.store.accountSnapshots[
                .copilot,
                default: [],
            ].append(TokenAccountUsageSnapshot(
                account: account,
                snapshot: snapshot,
                error: "Synthetic offline failure",
                sourceLabel: "fixture",
                cacheKey: self.store.tokenAccountSnapshotCacheKey(
                    provider: .copilot,
                    account: account)))
        }
        self.settings.setActiveTokenAccountIndex(
            0,
            for: .copilot)
        self.reconcile()
    }

    func reconcile() {
        self.store.reconcileSelectedTokenAccountSnapshotBeforeRefresh(
            provider: .copilot,
            accounts: self.settings.tokenAccounts(for: .copilot))
    }

    func stop() {
        self.settings.configFileWatcher?.stop()
        self.store.stopSharedSpendDashboardPublication()
    }
}
