import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CodexRemoteCostStoreTests {
    private actor LoaderHarness {
        var calls = 0
        var continuation: CheckedContinuation<CodexCombinedCostResult, any Error>?

        func load(_ request: CodexCombinedCostRequest) async throws -> CodexCombinedCostResult {
            self.calls += 1
            return try await withCheckedThrowingContinuation { self.continuation = $0 }
        }

        func finish(_ result: CodexCombinedCostResult) {
            self.continuation?.resume(returning: result)
            self.continuation = nil
        }

        func fail(_ error: any Error) {
            self.continuation?.resume(throwing: error)
            self.continuation = nil
        }
    }

    private static let now = Date(timeIntervalSince1970: 1_789_560_000)

    private func context(
        host: String = "synthetic-server",
        scope: String = "codex:ambient",
        days: Int = 7,
        now: Date = Self.now,
        pricing: String = "price-v1",
        ssh: String = "ssh-v1") -> CodexRemoteCostContext
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return CodexRemoteCostContext(
            source: .init(host: host),
            localCodexHome: URL(fileURLWithPath: "/synthetic/local"),
            localScope: scope,
            historyDays: days,
            calendar: calendar,
            day: calendar.startOfDay(for: now),
            pricingRevision: pricing,
            sshRevision: ssh,
            pricingCacheRoot: nil,
            localCostCacheRoot: nil,
            now: now)
    }

    private func snapshot(
        tokens: Int = 550,
        cost: Double = 1.83) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: tokens,
            sessionCostUSD: cost,
            last30DaysTokens: tokens + 165,
            last30DaysCostUSD: cost + 0.549,
            historyDays: 7,
            daily: [.init(
                date: "2026-09-16",
                inputTokens: tokens,
                outputTokens: 0,
                totalTokens: tokens,
                costUSD: cost,
                modelsUsed: [],
                modelBreakdowns: nil)],
            updatedAt: Self.now)
    }

    private func result(context: CodexRemoteCostContext) -> CodexCombinedCostResult {
        .init(
            snapshot: self.snapshot(),
            source: context.source,
            capturedFrom: Self.now,
            capturedTo: Self.now,
            notices: ["Synthetic estimate"])
    }

    private func manualStore(
        _ harness: LoaderHarness,
        defaults: InMemoryUserDefaults = InMemoryUserDefaults())
        -> CodexRemoteCostStore
    {
        let store = CodexRemoteCostStore(
            defaults: defaults,
            loader: { request, _ in try await harness.load(request) },
            cleanup: {})
        store.enabled = true
        store.host = "synthetic-server"
        return store
    }

    private func waitForCall(_ harness: LoaderHarness) async {
        for _ in 0..<1000 {
            if await harness.calls > 0 { return }
            await Task.yield()
        }
        Issue.record("Loader was not called")
    }

    private func waitForFinish(_ store: CodexRemoteCostStore) async {
        for _ in 0..<1000 {
            if !store.isRunning { return }
            await Task.yield()
        }
        Issue.record("Manual request did not finish")
    }

    @Test
    func `configuration saves and startup never fetch server logs`() async {
        let harness = LoaderHarness()
        let defaults = InMemoryUserDefaults()
        let store = self.manualStore(
            harness,
            defaults: defaults)
        store.home = "/synthetic/remote-codex"
        let context = self.context()
        store.reconcile(context)
        store.refresh(context: context) { context }
        #expect(await harness.calls == 0)
        #expect(store.result == nil)
        #expect(!store.consentGranted)
        let restored = self.manualStore(
            harness,
            defaults: defaults)
        #expect(restored.home == "/synthetic/remote-codex")
        #expect(restored.result == nil)
        #expect(CodexRemoteCostSettingsView.disclosure.contains("conversations and project paths"))
    }

    @Test
    func `only one explicit request runs and consent persists without results`() async {
        let harness = LoaderHarness()
        let defaults = InMemoryUserDefaults()
        let store = self.manualStore(
            harness,
            defaults: defaults)
        let context = self.context()
        store.grantConsent()
        store.refresh(context: context) { context }
        store.refresh(context: context) { context }
        await self.waitForCall(harness)
        #expect(await harness.calls == 1)
        await harness.finish(self.result(context: context))
        await self.waitForFinish(store)
        #expect(store.selectedResult(context: context)?.snapshot.sessionTokens == 550)
        let restored = self.manualStore(
            harness,
            defaults: defaults)
        #expect(restored.consentGranted)
        #expect(restored.result == nil)
    }

    @Test
    func `changed source rejects a late successful completion`() async {
        let harness = LoaderHarness()
        let store = self.manualStore(harness)
        let context = self.context()
        store.grantConsent()
        store.refresh(context: context) { context }
        await self.waitForCall(harness)
        store.host = "replacement-server"
        await harness.finish(self.result(context: context))
        await self.waitForFinish(store)
        #expect(store.result == nil)
        #expect(await harness.calls == 1)
    }

    @Test
    func `cancel waits for loader cleanup and cannot publish its late result`() async {
        let harness = LoaderHarness()
        let store = self.manualStore(harness)
        let context = self.context()
        store.grantConsent()
        store.refresh(context: context) { context }
        await self.waitForCall(harness)
        let cancellation = Task { await store.cancel() }
        await Task.yield()
        #expect(store.isRunning)
        await harness.finish(self.result(context: context))
        await cancellation.value
        #expect(!store.isRunning)
        #expect(store.result == nil)
    }

    @Test
    func `cleanup failure stays visible after disabling and permits explicit retry`() async {
        let harness = LoaderHarness()
        let store = self.manualStore(harness)
        let context = self.context()
        store.grantConsent()
        store.refresh(context: context) { context }
        await self.waitForCall(harness)
        store.enabled = false
        await harness.fail(CodexRemoteLogError.cleanupFailed)
        await self.waitForFinish(store)
        #expect(store.cleanupRequired)
        #expect(store.errorMessage != nil)
        await store.retryCleanup()
        #expect(!store.cleanupRequired)
        #expect(store.errorMessage == nil)
        #expect(await harness.calls == 1)
    }

    @Test
    func `window day pricing and SSH revisions invalidate frozen snapshots`() async {
        for changed in [
            self.context(days: 30), self.context(now: Self.now.addingTimeInterval(86400)),
            self.context(pricing: "price-v2"), self.context(ssh: "ssh-v2"),
            self.context(scope: "codex:managed:synthetic"),
        ] {
            let harness = LoaderHarness()
            let store = self.manualStore(harness)
            let context = self.context()
            store.grantConsent()
            store.refresh(context: context) { context }
            await self.waitForCall(harness)
            await harness.finish(self.result(context: context))
            await self.waitForFinish(store)
            #expect(store.selectedResult(context: changed) == nil)
            store.reconcile(changed)
            #expect(store.result == nil)
        }
    }

    @Test
    func `live context is checked again even without an observation notification`() async {
        let harness = LoaderHarness()
        let store = self.manualStore(harness)
        let context = self.context()
        let changed = self.context(pricing: "changed-during-transfer")
        store.grantConsent()
        store.refresh(context: context) { changed }
        await self.waitForCall(harness)
        await harness.finish(self.result(context: context))
        await self.waitForFinish(store)
        #expect(store.result == nil)
    }

    @Test
    func `abandoned cleanup failure prevents any new SSH request`() async {
        let harness = LoaderHarness()
        let store = CodexRemoteCostStore(
            defaults: InMemoryUserDefaults(),
            loader: { request, _ in try await harness.load(request) },
            cleanup: { throw CodexRemoteLogError.cleanupFailed })
        store.enabled = true
        store.host = "synthetic-server"
        store.grantConsent()
        let context = self.context()
        store.refresh(context: context) { context }
        await self.waitForFinish(store)
        #expect(await harness.calls == 0)
        #expect(store.cleanupRequired)
        #expect(store.errorMessage != nil)
    }

    @Test
    func `unverifiable SSH configuration blocks refresh before any remote request`() async {
        let harness = LoaderHarness()
        let store = self.manualStore(harness)
        let context = self.context(ssh: CodexRemoteLogMirror.unavailableConfigurationFingerprint)
        store.grantConsent()
        store.refresh(context: context) { context }
        #expect(await harness.calls == 0)
        #expect(store.errorMessage?.contains("configuration cannot be verified") == true)
        #expect(store.selectedResult(context: context) == nil)
    }

    @Test
    func `managed account scope cannot start a remote transaction`() async {
        let harness = LoaderHarness()
        let store = self.manualStore(harness)
        let context = self.context(scope: "codex:managed:synthetic")
        store.grantConsent()
        store.refresh(context: context) { context }
        #expect(await harness.calls == 0)
        #expect(!store.isRunning)
    }

    @Test
    func `ambient card and chart use frozen combined values while normal publication stays local`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = LoaderHarness()
        let defaults = InMemoryUserDefaults()
        let remote = self.manualStore(
            harness,
            defaults: defaults)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: CodexBarConfigStore(fileURL: root.appendingPathComponent("config.json")),
            keychainAccessPolicy: .init(
                setDisabled: { _ in },
                isExplicitlyDisabled: { true }),
            performInitialProviderDetection: false,
            isolatedStartup: true)
        settings.codexLocalSessionCostLedgerEnabled = true
        settings.costUsageHistoryDays = 7
        settings.costSummaryDisplayStyle = .both
        let environment = ["CODEX_HOME": root.appendingPathComponent("local-codex").path, "HOME": root.path]
        let fetcher = UsageFetcher(environment: environment)
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(homeDirectory: root.path),
            codexRemoteCostStore: remote,
            codexRemotePricingCacheRoot: root.appendingPathComponent("pricing"),
            codexRemoteLocalCostCacheRoot: root.appendingPathComponent("local-cache"),
            accountInfoOverride: AccountInfo(
                email: nil,
                plan: nil),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        let local = self.snapshot(
            tokens: 220,
            cost: 0.732)
        store.installCachedTokenSnapshot(
            local,
            for: .codex)
        let historyTokensTitle = "\(UsageMenuCardView.Model.costHistoryWindowLabel(days: 7)) \(L("tokens"))"
        let localKPIs = try #require(store.menuCardModel(for: .codex).inlineUsageDashboard?.kpis)
        #expect(localKPIs.suffix(2).map(\.title) == [L("Latest tokens"), historyTokensTitle])
        remote.grantConsent()
        let context = try await store.codexRemoteCostContext()
        remote.refresh(context: context) { context }
        await self.waitForCall(harness)
        await harness.finish(self.result(context: context))
        await self.waitForFinish(remote)
        #expect(store.codexCostPresentationSnapshot()?.sessionTokens == 550)
        #expect(store.tokenSnapshot(for: .codex)?.sessionTokens == 220)
        store._setTokenErrorForTesting("Unrelated local refresh failed", provider: .codex)
        let model = store.menuCardModel(for: .codex)
        #expect(model.tokenUsage?.errorLine == nil)
        #expect(model.tokenUsage?.sessionLine.contains("550") == true)
        #expect(model.inlineUsageDashboard?.detailLines.contains(where: { $0.contains("Native Codex") }) == true)
        let combinedKPIs = try #require(model.inlineUsageDashboard?.kpis)
        #expect(combinedKPIs.map(\.title) == [
            L("Today"), UsageMenuCardView.Model.costHistoryWindowLabel(days: 7), L("Today tokens"), historyTokensTitle,
        ])
        #expect(combinedKPIs.suffix(2).map(\.value) == ["550", "715"])
        let accountModel = store.menuCardModel(
            for: .codex,
            context: .account(.init(info: AccountInfo(
                email: nil,
                plan: nil))))
        #expect(accountModel.tokenUsage == nil)
        #expect(accountModel.inlineUsageDashboard == nil)
        store.installCachedTokenSnapshot(
            self.snapshot(
                tokens: 999,
                cost: 9.99),
            for: .codex)
        #expect(store.codexCostPresentationSnapshot()?.sessionTokens == 550)
        #expect(store.tokenSnapshot(for: .codex)?.sessionTokens == 999)
        // The explicit SSH presentation remains available with ordinary cost collection switched off.
        settings.codexLocalSessionCostLedgerEnabled = false
        settings.costUsageEnabled = false
        store.clearTokenSnapshot(for: .codex)
        #expect(store.menuCardModel(for: .codex).tokenUsage?.sessionLine.contains("550") == true)
        #expect(store.costPresentationShowsSubmenu(for: .codex))
        store.installCachedTokenSnapshot(
            self.snapshot(
                tokens: 999,
                cost: 9.99),
            for: .codex)
        settings.hidePersonalInfo = true
        #expect(store.codexRemoteCostPresentation()?.title.contains("synthetic-server") == false)
        remote.enabled = false
        #expect(store.codexCostPresentationSnapshot()?.sessionTokens == 999)
        remote.enabled = true
        #expect(store.codexRemoteCostPresentation()?.title == "Only this Mac")
        #expect(store.codexRemoteCostPresentation()?.detail.contains("Native Codex logs") == false)
        await remote.cancel()
        #expect(store.codexRemoteCostPresentation()?.status == "Server refresh cancelled. Only this Mac is shown.")
        store.clearTokenSnapshot(for: .codex)
        #expect(store.menuCardModel(for: .codex).tokenUsage?.sessionLine.contains("unavailable") == true)
        #expect(store.codexRemoteCostPresentation()?.status.contains("no zero amount") == true)
    }
}
