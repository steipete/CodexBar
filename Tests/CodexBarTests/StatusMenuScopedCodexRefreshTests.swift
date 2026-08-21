import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuScopedCodexRefreshTests {
    @Test
    func `scoped refresh publishes compatible quota before dashboard enrichment completes`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = false
        settings.showOptionalCreditsAndExtraUsage = true
        settings.openAIWebAccessEnabled = true
        settings.codexCookieSource = .manual
        settings.codexCookieHeader = "session=fixture"
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "fixture@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "fixture@example.com"))
        settings.codexActiveSource = .liveSystem
        self.enableOnlyCodex(settings)
        defer { settings._test_liveSystemCodexAccount = nil }

        let account = AccountInfo(email: "fixture@example.com", plan: "pro")
        let environment = Self.isolatedEnvironment()
        let fetcher = UsageFetcher(environment: environment)
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        store.accountInfoCache[.codex] = UsageStore.AccountInfoCacheEntry(
            account: account,
            configRevision: settings.configRevision,
            expiresAt: .distantFuture)
        let initialUpdatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        store.snapshots[.codex] = Self.snapshot(usedPercent: 12, updatedAt: initialUpdatedAt)

        try await withStatusItemControllerForTesting(
            store: store,
            settings: settings,
            fetcher: fetcher,
            account: account)
        { controller in
            let creditsStarted = CodexAccountScopedRefreshSignal()
            let releaseCredits = CodexAccountScopedRefreshSignal()
            let monitor = controller.menuCardRefreshMonitor
            let frozen = try #require(controller.menuCardModel(for: .codex))
            var coreModel: UsageMenuCardView.Model?
            var creditsLoaderCalls = 0
            var dashboardLoaderCalls = 0

            store._test_providerRefreshOverride = { provider in
                #expect(provider == .codex)
                store.snapshots[.codex] = Self.snapshot(
                    usedPercent: 37,
                    updatedAt: initialUpdatedAt.addingTimeInterval(60))
                store.errors[.codex] = nil
                coreModel = controller.menuCardModel(for: .codex)
            }
            store._test_codexCreditsLoaderOverride = {
                creditsLoaderCalls += 1
                if creditsLoaderCalls == 1 {
                    creditsStarted.signal()
                    await releaseCredits.wait()
                }
                return CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())
            }
            store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
                dashboardLoaderCalls += 1
                return OpenAIDashboardSnapshot(
                    signedInEmail: account.email,
                    codeReviewRemainingPercent: 95,
                    creditEvents: [],
                    dailyBreakdown: [],
                    usageBreakdown: [],
                    creditsPurchaseURL: nil,
                    creditsRemaining: 25,
                    accountPlan: "Pro",
                    updatedAt: Date())
            }
            defer {
                releaseCredits.signal()
                monitor.endManualRefresh(for: .codex)
                store._test_providerRefreshOverride = nil
                store._test_codexCreditsLoaderOverride = nil
                store._test_openAIDashboardLoaderOverride = nil
            }

            monitor.beginManualRefresh(frozenModels: [.codex: frozen], provider: .codex)
            let refreshTask = Task { @MainActor in
                await controller.performStoreRefresh(
                    for: .codex,
                    refreshOpenMenusWhenComplete: false,
                    interaction: .userInitiated)
            }
            let enrichmentDidStart = await creditsStarted.waitUntilSignaled()
            #expect(enrichmentDidStart)
            guard enrichmentDidStart else {
                await refreshTask.value
                return
            }

            let expectedCore = try #require(coreModel)
            let visibleWhileBlocked = monitor.model(for: .codex, fallback: frozen)
            #expect(!monitor.isManualRefreshInFlight(for: .codex))
            #expect(visibleWhileBlocked.metrics.map(\.percent) == expectedCore.metrics.map(\.percent))
            #expect(visibleWhileBlocked.metrics.map(\.percent) != frozen.metrics.map(\.percent))
            self.emitProbe(
                "compatible enrichment=blocked refreshing=false before=" +
                    "\(frozen.metrics.first?.percentLabel ?? "none") core=" +
                    "\(visibleWhileBlocked.metrics.first?.percentLabel ?? "none")")

            releaseCredits.signal()
            await refreshTask.value

            let finalModel = try #require(controller.menuCardModel(for: .codex))
            let visibleAfterEnrichment = monitor.model(for: .codex, fallback: finalModel)
            #expect(store.credits?.remaining == 25)
            #expect(store.openAIDashboard?.creditsRemaining == 25)
            #expect(creditsLoaderCalls >= 1)
            #expect(dashboardLoaderCalls >= 1)
            #expect(visibleAfterEnrichment.hasCompatibleTrackedLayout(with: finalModel))
            self.emitProbe(
                "compatible enrichment=complete credits=\(store.credits?.remaining ?? -1) " +
                    "dashboardCredits=\(store.openAIDashboard?.creditsRemaining ?? -1)")
        }
    }

    @Test
    func `scoped refresh reconciles usage after dashboard login expires`() async {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.openAIWebAccessEnabled = true
        settings.codexCookieSource = .auto
        self.enableOnlyCodex(settings)

        let account = AccountInfo(email: "test@example.com", plan: "pro")
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store.accountInfoCache[.codex] = UsageStore.AccountInfoCacheEntry(
            account: account,
            configRevision: settings.configRevision,
            expiresAt: .distantFuture)
        await withStatusItemControllerForTesting(
            store: store,
            settings: settings,
            fetcher: fetcher,
            account: account)
        { controller in
            var providerRefreshes = 0
            store._test_providerRefreshOverride = { provider in
                #expect(provider == .codex)
                providerRefreshes += 1
            }
            store._test_tokenUsageRefreshOverride = { _, _ in }
            store._test_codexCreditsLoaderOverride = {
                CreditsSnapshot(remaining: 25, events: [], updatedAt: Date())
            }
            store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
                throw OpenAIDashboardFetcher.FetchError.loginRequired
            }
            store._test_openAIDashboardCookieImportOverride = { targetEmail, _, _, _, _ in
                OpenAIDashboardBrowserCookieImporter.ImportResult(
                    sourceLabel: "Chrome",
                    cookieCount: 2,
                    signedInEmail: targetEmail,
                    matchesCodexEmail: true)
            }
            defer {
                store._test_providerRefreshOverride = nil
                store._test_tokenUsageRefreshOverride = nil
                store._test_codexCreditsLoaderOverride = nil
                store._test_openAIDashboardLoaderOverride = nil
                store._test_openAIDashboardCookieImportOverride = nil
            }

            await controller.performStoreRefresh(
                for: .codex,
                refreshOpenMenusWhenComplete: false,
                interaction: .userInitiated)

            #expect(store.openAIDashboardRequiresLogin)
            #expect(providerRefreshes == 2)
        }
    }

    @Test
    func `account transition forces codex once after joined sequence already passed its lane`() async {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.costUsageEnabled = true
        settings.codexLocalSessionCostLedgerEnabled = false
        settings.cursorCookieSource = .manual
        settings.cursorCookieHeader = "fixture=cursor"
        let profileA = "/tmp/status-menu-codex-a"
        let profileB = "/tmp/status-menu-codex-b"
        settings.updateProviderConfig(provider: .codex) { config in
            config.codexProfileHomePaths = [profileA, profileB]
            config.codexActiveSource = .profileHome(path: profileA)
        }
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: metadata,
                enabled: provider == .codex || provider == .cursor)
        }
        let environment = Self.isolatedEnvironment()
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        store._test_providerRefreshOverride = { _ in }
        store._test_codexCreditsLoaderOverride = {
            CreditsSnapshot(remaining: 1, events: [], updatedAt: Date())
        }
        let laterLaneStarted = CodexAccountScopedRefreshSignal()
        let releaseLaterLane = CodexAccountScopedRefreshSignal()
        var codexRequests: [(force: Bool, homePath: String?)] = []
        store._test_tokenUsageRefreshOverride = { provider, force in
            if provider == .codex {
                codexRequests.append((force, store.tokenCostScope(for: .codex).codexHomePath))
            } else if provider == .cursor {
                laterLaneStarted.signal()
                await releaseLaterLane.wait()
            }
        }
        defer {
            releaseLaterLane.signal()
            store._test_providerRefreshOverride = nil
            store._test_codexCreditsLoaderOverride = nil
            store._test_tokenUsageRefreshOverride = nil
        }

        store.lastForcedTokenRefreshStartedAt = Date()
        store.scheduleTokenRefreshForTesting()
        #expect(await laterLaneStarted.waitUntilSignaled())

        let priorScope = store.tokenSnapshotScopeSignature(for: .codex)
        settings.codexActiveSource = .profileHome(path: profileB)
        let accountRefresh = Task {
            await store.refreshCodexAccountScopedState(
                allowDisabled: true,
                priorTokenScopeSignature: priorScope)
        }
        await Task.yield()
        #expect(codexRequests.map(\.force) == [false])

        releaseLaterLane.signal()
        await accountRefresh.value

        #expect(codexRequests.map(\.force) == [false, true])
        #expect(codexRequests.map(\.homePath) == [profileA, profileB])
    }

    @Test
    func `forced replacement revalidates blocked profile transition after drain`() async {
        let settings = self.makeSettings()
        settings.costUsageEnabled = true
        settings.codexLocalSessionCostLedgerEnabled = false
        let profileA = "/tmp/status-menu-drain-a"
        let profileB = "/tmp/status-menu-drain-b"
        settings.updateProviderConfig(provider: .codex) { config in
            config.codexProfileHomePaths = [profileA, profileB]
            config.codexActiveSource = .profileHome(path: profileA)
        }
        self.enableOnlyCodex(settings)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: Self.isolatedEnvironment()),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: Self.isolatedEnvironment())
        var scans: [String?] = []
        store._test_tokenUsageRefreshOverride = { provider, force in
            #expect(provider == .codex)
            #expect(force)
            scans.append(store.tokenCostScope(for: .codex).codexHomePath)
        }
        let sequenceInstalled = CodexAccountScopedRefreshSignal()
        let releaseSequence = CodexAccountScopedRefreshSignal()
        store._test_tokenRefreshSequenceStartBarrier = {
            sequenceInstalled.signal()
            await releaseSequence.wait()
        }
        defer {
            releaseSequence.signal()
            store._test_tokenUsageRefreshOverride = nil
            store._test_tokenRefreshSequenceStartBarrier = nil
        }

        settings.codexActiveSource = .profileHome(path: profileB)
        let capturedRevision = settings.providerConfigRevision(for: .codex)
        let capturedScope = store.tokenSnapshotScopeSignature(for: .codex)
        let drainStarted = CodexAccountScopedRefreshSignal()
        let releaseDrain = CodexAccountScopedRefreshSignal()
        let blockingTask = Task { @MainActor in
            drainStarted.signal()
            await releaseDrain.wait()
            store.tokenRefreshSequenceTask = nil
            store.tokenRefreshSequenceProvider = nil
        }
        store.tokenRefreshSequenceTask = blockingTask
        store.tokenRefreshSequenceProvider = UsageProvider.codex.instanceID
        defer { releaseDrain.signal() }

        let staleReplacement = Task { @MainActor in
            await store.refreshTokenUsageNow(for: .codex, force: true) {
                settings.providerConfigRevision(for: .codex) == capturedRevision &&
                    store.tokenSnapshotScopeSignature(for: .codex) == capturedScope
            }
        }
        #expect(await drainStarted.waitUntilSignaled())

        releaseDrain.signal()
        #expect(await sequenceInstalled.waitUntilSignaled())
        settings.codexActiveSource = .profileHome(path: profileA)
        releaseSequence.signal()
        await staleReplacement.value

        #expect(scans.isEmpty)
        store._test_tokenRefreshSequenceStartBarrier = nil
        await store.refreshTokenUsageNow(for: .codex, force: true)
        #expect(scans == [profileA])
    }

    private func makeSettings() -> SettingsStore {
        testSettingsStore(suiteName: "StatusMenuScopedCodexRefreshTests")
    }

    private func enableOnlyCodex(_ settings: SettingsStore) {
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }
    }

    private static func isolatedEnvironment() -> [String: String] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex", isDirectory: true).path,
            "XDG_CONFIG_HOME": root.appendingPathComponent(".config", isDirectory: true).path,
        ]
    }

    private static func snapshot(
        usedPercent: Double,
        secondaryUsedPercent: Double? = nil,
        updatedAt: Date) -> UsageSnapshot
    {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 300,
                resetsAt: updatedAt.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: secondaryUsedPercent.map { percent in
                RateWindow(
                    usedPercent: percent,
                    windowMinutes: 10080,
                    resetsAt: updatedAt.addingTimeInterval(7200),
                    resetDescription: nil)
            },
            updatedAt: updatedAt)
    }

    private func emitProbe(_ line: String) {
        guard ProcessInfo.processInfo.environment["CODEXBAR_REFRESH_PROBE"] == "1" else { return }
        let data = Data("CODEXBAR_REFRESH_PROBE \(line)\n".utf8)
        FileHandle.standardError.write(data)
    }
}
