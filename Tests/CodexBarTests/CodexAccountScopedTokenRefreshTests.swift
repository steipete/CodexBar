import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `account transition starts nonforced token refresh then one forced fallback for selected profile`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedTokenRefreshTests-profile-fallback")
        settings.costUsageEnabled = true
        settings.codexLocalSessionCostLedgerEnabled = false
        let profileA = "/tmp/codex-profile-a"
        let profileB = "/tmp/codex-profile-b"
        settings.updateProviderConfig(provider: .codex) { config in
            config.codexProfileHomePaths = [profileA, profileB]
            config.codexActiveSource = .profileHome(path: profileA)
        }
        let store = self.makeUsageStore(settings: settings)
        store._test_providerRefreshOverride = { _ in }
        store._test_codexCreditsLoaderOverride = { self.credits(remaining: 1) }
        var requests: [(force: Bool, homePath: String?)] = []
        store._test_tokenUsageRefreshOverride = { provider, force in
            #expect(provider == .codex)
            requests.append((force, store.tokenCostScope(for: .codex).codexHomePath))
        }
        defer {
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_tokenUsageRefreshOverride = nil
        }

        let priorScope = store.tokenSnapshotScopeSignature(for: .codex)
        settings.codexActiveSource = .profileHome(path: profileB)
        await store.refreshCodexAccountScopedState(
            allowDisabled: true,
            priorTokenScopeSignature: priorScope)

        #expect(requests.map(\.force) == [false, true])
        #expect(requests.map(\.homePath) == [profileB, profileB])
    }

    @Test
    func `current confirmed empty token publication stops forced fallback`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedTokenRefreshTests-confirmed-empty")
        settings.costUsageEnabled = true
        let store = self.makeUsageStore(settings: settings)
        store._test_providerRefreshOverride = { _ in }
        store._test_codexCreditsLoaderOverride = { self.credits(remaining: 1) }
        var requests: [Bool] = []
        store._test_tokenUsageRefreshOverride = { provider, force in
            requests.append(force)
            if provider == .codex, !force {
                store.publishConfirmedEmptyTokenSnapshot(for: .codex)
            }
        }
        defer {
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_tokenUsageRefreshOverride = nil
        }

        await store.refreshCodexAccountScopedState(allowDisabled: true)

        #expect(requests == [false])
        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex) != nil)
        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex)?.snapshot == nil)
    }

    @Test
    func `token lane skips cost off and disabled codex`() async throws {
        let costOffSettings = self.makeSettingsStore(suite: "CodexAccountScopedTokenRefreshTests-cost-off")
        costOffSettings.costUsageEnabled = false
        costOffSettings.codexLocalSessionCostLedgerEnabled = false
        let costOffStore = self.makeUsageStore(settings: costOffSettings)
        costOffStore._test_providerRefreshOverride = { _ in }
        costOffStore._test_codexCreditsLoaderOverride = { self.credits(remaining: 1) }
        var costOffRequests = 0
        costOffStore._test_tokenUsageRefreshOverride = { _, _ in costOffRequests += 1 }
        await costOffStore.refreshCodexAccountScopedState(allowDisabled: true)
        #expect(costOffRequests == 0)

        let disabledSettings = self.makeSettingsStore(suite: "CodexAccountScopedTokenRefreshTests-disabled")
        disabledSettings.costUsageEnabled = true
        let codexMetadata = try #require(ProviderRegistry.shared.metadata[.codex])
        disabledSettings.setProviderEnabled(
            provider: .codex,
            metadata: codexMetadata,
            enabled: false)
        let disabledStore = self.makeUsageStore(settings: disabledSettings)
        disabledStore._test_providerRefreshOverride = { _ in }
        disabledStore._test_codexCreditsLoaderOverride = { self.credits(remaining: 1) }
        var disabledRequests = 0
        disabledStore._test_tokenUsageRefreshOverride = { _, _ in disabledRequests += 1 }
        await disabledStore.refreshCodexAccountScopedState(allowDisabled: true)
        #expect(disabledRequests == 0)
    }

    @Test
    func `old aba transition cannot force fallback and newest transition can`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedTokenRefreshTests-aba")
        settings.costUsageEnabled = true
        settings.codexLocalSessionCostLedgerEnabled = false
        let profileA = "/tmp/codex-aba-a"
        let profileB = "/tmp/codex-aba-b"
        settings.updateProviderConfig(provider: .codex) { config in
            config.codexProfileHomePaths = [profileA, profileB]
            config.codexActiveSource = .profileHome(path: profileA)
        }
        let store = self.makeUsageStore(settings: settings)
        store._test_providerRefreshOverride = { _ in }
        store._test_codexCreditsLoaderOverride = { self.credits(remaining: 1) }
        let firstStarted = CodexAccountScopedRefreshSignal()
        let releaseFirst = CodexAccountScopedRefreshSignal()
        var requests: [(Bool, String?)] = []
        store._test_tokenUsageRefreshOverride = { _, force in
            let homePath = store.tokenCostScope(for: .codex).codexHomePath
            requests.append((force, homePath))
            if requests.count == 1 {
                firstStarted.signal()
                await releaseFirst.wait()
            }
        }
        defer {
            releaseFirst.signal()
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_tokenUsageRefreshOverride = nil
        }

        let scopeA = store.tokenSnapshotScopeSignature(for: .codex)
        settings.codexActiveSource = .profileHome(path: profileB)
        let oldTransition = Task {
            await store.refreshCodexAccountScopedState(
                allowDisabled: true,
                priorTokenScopeSignature: scopeA)
        }
        #expect(await firstStarted.waitUntilSignaled())

        let scopeB = store.tokenSnapshotScopeSignature(for: .codex)
        settings.codexActiveSource = .profileHome(path: profileA)
        releaseFirst.signal()
        await oldTransition.value
        #expect(requests.map(\.0) == [false])

        await store.refreshCodexAccountScopedState(
            allowDisabled: true,
            priorTokenScopeSignature: scopeB)
        #expect(requests.map(\.0) == [false, false, true])
        #expect(requests.map(\.1) == [profileB, profileA, profileA])
    }

    @Test
    func `cancelling account refresh cancels token wait without fallback`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedTokenRefreshTests-cancel")
        settings.costUsageEnabled = true
        settings.codexActiveSource = .profileHome(path: "/tmp/codex-cancel")
        let store = self.makeUsageStore(settings: settings)
        store._test_providerRefreshOverride = { _ in }
        store._test_codexCreditsLoaderOverride = { self.credits(remaining: 1) }
        let started = CodexAccountScopedRefreshSignal()
        var requests: [Bool] = []
        var observedCancellation = false
        store._test_tokenUsageRefreshOverride = { _, force in
            requests.append(force)
            started.signal()
            do {
                try await Task.sleep(for: .seconds(1))
            } catch is CancellationError {
                observedCancellation = true
            } catch {}
        }
        defer {
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_tokenUsageRefreshOverride = nil
        }

        let refreshTask = Task { await store.refreshCodexAccountScopedState(allowDisabled: true) }
        #expect(await started.waitUntilSignaled())
        refreshTask.cancel()
        await refreshTask.value

        #expect(requests == [false])
        #expect(observedCancellation)
        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex) == nil)
    }

    @Test
    func `ambient publication compatibility does not relax in flight completion guard`() {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedTokenRefreshTests-ambient-strict")
        settings.costUsageEnabled = true
        settings.codexLocalSessionCostLedgerEnabled = true
        let profileA = "/tmp/codex-ambient-strict-a"
        let profileB = "/tmp/codex-ambient-strict-b"
        settings.updateProviderConfig(provider: .codex) { config in
            config.codexProfileHomePaths = [profileA, profileB]
            config.codexActiveSource = .profileHome(path: profileA)
        }
        let store = self.makeUsageStore(settings: settings)
        let snapshot = self.tokenSnapshot(cost: 1)
        store._setTokenSnapshotForTesting(snapshot, provider: .codex)
        let publicationRevision = store.providerPublicationRevision(for: .codex)
        let providerConfigRevision = settings.providerConfigRevision(for: .codex)
        let historyDays = settings.costUsageHistoryDays
        let costScopeSignature = store.tokenSnapshotScopeSignature(for: .codex)

        settings.codexActiveSource = .profileHome(path: profileB)

        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex)?.snapshot == snapshot)
        #expect(!store.tokenRefreshPublicationIsCurrent(
            provider: .codex,
            publicationRevision: publicationRevision,
            providerConfigRevision: providerConfigRevision,
            historyDays: historyDays,
            costScopeSignature: costScopeSignature))
    }

    @Test
    func `token errors clear only when activation changes full token scope`() {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedTokenRefreshTests-errors")
        settings.costUsageEnabled = true
        settings.codexLocalSessionCostLedgerEnabled = false
        let profileA = "/tmp/codex-errors-a"
        let profileB = "/tmp/codex-errors-b"
        settings.updateProviderConfig(provider: .codex) { config in
            config.codexProfileHomePaths = [profileA, profileB]
            config.codexActiveSource = .profileHome(path: profileA)
        }
        let store = self.makeUsageStore(settings: settings)
        store.tokenErrors[.codex] = "profile A failed"
        _ = store.tokenFailureGates[.codex]?.shouldSurfaceError(onFailureWithPriorData: false)
        let profileAScope = store.tokenSnapshotScopeSignature(for: .codex)

        settings.codexActiveSource = .profileHome(path: profileB)
        _ = store.prepareCodexAccountScopedRefreshIfNeeded(priorTokenScopeSignature: profileAScope)
        #expect(store.tokenErrors[.codex] == nil)
        #expect(store.tokenFailureGates[.codex]?.streak == 0)

        settings.codexLocalSessionCostLedgerEnabled = true
        store.tokenErrors[.codex] = "ambient failed"
        _ = store.tokenFailureGates[.codex]?.shouldSurfaceError(onFailureWithPriorData: false)
        let ambientScope = store.tokenSnapshotScopeSignature(for: .codex)
        settings.codexActiveSource = .profileHome(path: profileA)
        _ = store.prepareCodexAccountScopedRefreshIfNeeded(priorTokenScopeSignature: ambientScope)
        #expect(store.tokenErrors[.codex] == "ambient failed")
        #expect(store.tokenFailureGates[.codex]?.streak == 1)
    }

    @Test
    func `first profile scope change invalidates while duplicate and ambient selections do not`() {
        let profileA = "/tmp/codex-first-invalidation-a"
        let profileB = "/tmp/codex-first-invalidation-b"
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedTokenRefreshTests-first-invalidation")
        settings.costUsageEnabled = true
        settings.codexLocalSessionCostLedgerEnabled = false
        settings.updateProviderConfig(provider: .codex) { config in
            config.codexProfileHomePaths = [profileA, profileB]
            config.codexActiveSource = .profileHome(path: profileA)
        }
        let store = self.makeUsageStore(settings: settings)
        store._setSnapshotForTesting(
            self.codexSnapshot(email: "profile-a@example.com", usedPercent: 12),
            provider: .codex)
        let profileAScope = store.tokenSnapshotScopeSignature(for: .codex)

        #expect(store.lastCodexAccountScopedRefreshGuard == nil)
        settings.codexActiveSource = .profileHome(path: profileB)
        #expect(store.prepareCodexAccountScopedRefreshIfNeeded(priorTokenScopeSignature: profileAScope))
        #expect(store.snapshots[.codex] == nil)

        let profileBScope = store.tokenSnapshotScopeSignature(for: .codex)
        #expect(!store.prepareCodexAccountScopedRefreshIfNeeded(priorTokenScopeSignature: profileBScope))

        let ambientSettings = self.makeSettingsStore(
            suite: "CodexAccountScopedTokenRefreshTests-first-invalidation-ambient")
        ambientSettings.costUsageEnabled = true
        ambientSettings.codexLocalSessionCostLedgerEnabled = true
        ambientSettings.updateProviderConfig(provider: .codex) { config in
            config.codexProfileHomePaths = [profileA, profileB]
            config.codexActiveSource = .profileHome(path: profileA)
        }
        let ambientStore = self.makeUsageStore(settings: ambientSettings)
        let ambientScope = ambientStore.tokenSnapshotScopeSignature(for: .codex)
        ambientSettings.codexActiveSource = .profileHome(path: profileB)

        #expect(ambientStore.lastCodexAccountScopedRefreshGuard == nil)
        #expect(!ambientStore.prepareCodexAccountScopedRefreshIfNeeded(
            priorTokenScopeSignature: ambientScope))
    }

    @Test
    func `settings card hides prior profile cost while selected profile scan is blocked`() async {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedTokenRefreshTests-settings-card")
        settings.costUsageEnabled = true
        settings.codexLocalSessionCostLedgerEnabled = false
        let profileA = "/tmp/codex-settings-card-a"
        let profileB = "/tmp/codex-settings-card-b"
        settings.updateProviderConfig(provider: .codex) { config in
            config.codexProfileHomePaths = [profileA, profileB]
            config.codexActiveSource = .profileHome(path: profileA)
        }
        let store = self.makeUsageStore(settings: settings)
        store._setTokenSnapshotForTesting(self.tokenSnapshot(cost: 1), provider: .codex)
        store._test_providerRefreshOverride = { _ in }
        store._test_codexCreditsLoaderOverride = { self.credits(remaining: 1) }
        let scanStarted = CodexAccountScopedRefreshSignal()
        let releaseScan = CodexAccountScopedRefreshSignal()
        store._test_tokenUsageSnapshotLoaderOverride = { provider, _, _, homePath, _ in
            #expect(provider == .codex)
            #expect(homePath == profileB)
            scanStarted.signal()
            await releaseScan.wait()
            return self.tokenSnapshot(cost: 2)
        }
        defer {
            releaseScan.signal()
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_tokenUsageSnapshotLoaderOverride = nil
        }

        let pane = ProvidersPane(settings: settings, store: store)
        #expect(pane.menuCardModel(for: .codex).tokenUsage != nil)
        let priorScope = store.tokenSnapshotScopeSignature(for: .codex)
        settings.codexActiveSource = .profileHome(path: profileB)
        let refresh = Task {
            await store.refreshCodexAccountScopedState(
                allowDisabled: true,
                priorTokenScopeSignature: priorScope)
        }
        #expect(await scanStarted.waitUntilSignaled())

        #expect(store.tokenSnapshot(for: .codex)?.last30DaysCostUSD == 1)
        #expect(pane.menuCardModel(for: .codex).tokenUsage == nil)

        releaseScan.signal()
        await refresh.value
        #expect(pane.menuCardModel(for: .codex).tokenUsage?.sessionLine.contains("20") == true)
    }

    @Test
    func `first managed switch rebuilds tracked popup before and after scoped token refresh`() async throws {
        let settings = self.makeSettingsStore(suite: "CodexAccountScopedTokenRefreshTests-popup")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.multiAccountMenuLayout = .segmented
        settings.costUsageEnabled = true
        settings.costSummaryDisplayStyle = .both
        settings.codexLocalSessionCostLedgerEnabled = false
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }

        let managedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let managedHomeA = managedRoot.appendingPathComponent("managed-a", isDirectory: true)
        let managedHomeB = managedRoot.appendingPathComponent("managed-b", isDirectory: true)
        let managedStoreURL = managedRoot.appendingPathComponent("accounts.json")
        let missingLiveHome = managedRoot.appendingPathComponent("missing-live", isDirectory: true)
        try Self.writeCodexAuthFile(homeURL: managedHomeA, email: "managed-a@example.com", plan: "pro")
        try Self.writeCodexAuthFile(homeURL: managedHomeB, email: "managed-b@example.com", plan: "pro")
        let managedAccountA = ManagedCodexAccount(
            id: UUID(),
            email: "managed-a@example.com",
            managedHomePath: managedHomeA.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let managedAccountB = ManagedCodexAccount(
            id: UUID(),
            email: "managed-b@example.com",
            managedHomePath: managedHomeB.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let managedStore = FileManagedCodexAccountStore(fileURL: managedStoreURL)
        try managedStore.storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [managedAccountA, managedAccountB]))
        settings._test_managedCodexAccountStoreURL = managedStoreURL
        settings._test_codexReconciliationEnvironment = ["CODEX_HOME": missingLiveHome.path]
        settings.codexActiveSource = .managedAccount(id: managedAccountA.id)
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: managedRoot)
        }

        let visibleAccounts = settings.codexVisibleAccountProjection.visibleAccounts
        #expect(visibleAccounts.count == 2)
        #expect(settings.codexResolvedActiveSource == .managedAccount(id: managedAccountA.id))
        let store = self.makeUsageStore(settings: settings)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 12,
                    windowMinutes: 300,
                    resetsAt: Date().addingTimeInterval(300),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .codex)
        store._setTokenSnapshotForTesting(self.tokenSnapshot(cost: 1), provider: .codex)
        store._test_providerRefreshOverride = { _ in }
        store._test_codexCreditsLoaderOverride = { self.credits(remaining: 1) }
        let scanStarted = CodexAccountScopedRefreshSignal()
        let releaseScan = CodexAccountScopedRefreshSignal()
        store._test_tokenUsageSnapshotLoaderOverride = { provider, _, _, homePath, _ in
            #expect(provider == .codex)
            #expect(homePath == managedHomeB.path)
            scanStarted.signal()
            await releaseScan.wait()
            return self.tokenSnapshot(cost: 2)
        }
        defer {
            releaseScan.signal()
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_tokenUsageSnapshotLoaderOverride = nil
        }
        _ = settings.codexVisibleAccountProjection

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system,
            menuCardRenderingEnabled: true,
            menuRefreshEnabled: true,
            observeProviderConfigNotifications: false)
        controller._test_providerSwitcherMenuRebuildDebounceNanoseconds = 0
        defer { controller.releaseStatusItemsForTesting() }

        #expect(store.lastCodexAccountScopedRefreshGuard == nil)
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        let switcher = try #require(menu.items.compactMap { $0.view as? CodexAccountSwitcherView }.first)
        let managedBVisibleAccount = try #require(visibleAccounts.first {
            $0.selectionSource == .managedAccount(id: managedAccountB.id)
        })
        _ = try #require(self.menuItem(in: menu, id: "menuCardCost"))
        #expect(store.tokenSnapshotForCurrentProviderConfig(for: .codex)?.snapshot.last30DaysCostUSD == 1)
        #expect(self.menuContainsRepresentedObject(StatusItemController.costHistoryChartID, in: menu))

        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { rebuiltMenu in
            if rebuiltMenu === menu { rebuildCount += 1 }
        }
        defer { controller._test_openMenuRebuildObserver = nil }
        switcher._test_selectAccount(id: managedBVisibleAccount.id)
        #expect(await scanStarted.waitUntilSignaled())

        let rebuildDeadline = ContinuousClock.now + .seconds(5)
        while rebuildCount == 0 || self.menuItem(in: menu, id: "menuCardCost") != nil,
              ContinuousClock.now < rebuildDeadline
        {
            await Task.yield()
        }
        #expect(settings.codexActiveSource == .managedAccount(id: managedAccountB.id))
        #expect(settings.codexResolvedActiveSource == .managedAccount(id: managedAccountB.id))
        #expect(rebuildCount > 0)
        #expect(self.menuItem(in: menu, id: "menuCardCost") == nil)
        #expect(!self.menuContainsRepresentedObject(StatusItemController.costHistoryChartID, in: menu))

        releaseScan.signal()
        let publicationDeadline = ContinuousClock.now + .seconds(5)
        while self.menuItem(in: menu, id: "menuCardCost") == nil ||
            store.tokenSnapshotForCurrentProviderConfig(for: .codex)?.snapshot.last30DaysCostUSD != 2,
            ContinuousClock.now < publicationDeadline
        {
            await Task.yield()
        }

        _ = try #require(self.menuItem(in: menu, id: "menuCardCost"))
        #expect(store.tokenSnapshotForCurrentProviderConfig(for: .codex)?.snapshot.last30DaysCostUSD == 2)
        #expect(self.menuContainsRepresentedObject(StatusItemController.costHistoryChartID, in: menu))
    }

    private func menuItem(in menu: NSMenu, id: String) -> NSMenuItem? {
        menu.items.first { $0.representedObject as? String == id }
    }

    private func menuContainsRepresentedObject(_ id: String, in menu: NSMenu) -> Bool {
        menu.items.contains { item in
            item.representedObject as? String == id ||
                item.submenu.map { self.menuContainsRepresentedObject(id, in: $0) } == true
        }
    }

    private func tokenSnapshot(cost: Double) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: Int(cost * 10),
            sessionCostUSD: cost,
            last30DaysTokens: Int(cost * 100),
            last30DaysCostUSD: cost,
            meteredCostUSD: cost,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-08-22",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: Int(cost * 10),
                    costUSD: cost,
                    modelsUsed: ["fixture-model"],
                    modelBreakdowns: nil),
            ],
            updatedAt: Date())
    }
}
