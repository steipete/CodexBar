import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
private final class ScopedRefreshGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if self.isOpen {
            self.isOpen = false
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        if let continuation = self.continuation {
            continuation.resume()
            self.continuation = nil
        } else {
            self.isOpen = true
        }
    }

    func waitUntilSignaled(timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !self.isOpen {
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        self.isOpen = false
        return true
    }
}

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
            let creditsStarted = ScopedRefreshGate()
            let releaseCredits = ScopedRefreshGate()
            let monitor = controller.menuCardRefreshMonitor
            let frozen = try #require(controller.menuCardModel(for: .codex))
            var coreModel: UsageMenuCardView.Model?
            var creditsLoaderCalls = 0
            var dashboardLoaderCalls = 0

            store._test_providerRefreshOverride = { provider in
                #expect(provider == .codex)
                // A settings reload can invalidate the revision-bound fallback account cache.
                store.accountInfoCache[.codex] = nil
                store.snapshots[.codex] = Self.snapshot(
                    usedPercent: 37,
                    updatedAt: initialUpdatedAt.addingTimeInterval(60))
                store.errors[.codex] = nil
                coreModel = controller.menuCardModel(for: .codex)
            }
            store._test_codexCreditsLoaderOverride = {
                creditsLoaderCalls += 1
                if creditsLoaderCalls == 1 {
                    creditsStarted.resume()
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
                releaseCredits.resume()
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
                releaseCredits.resume()
                await refreshTask.value
                return
            }

            let expectedCore = try #require(coreModel)
            #expect(frozen.hasCompatibleTrackedLayout(with: expectedCore))
            let visibleWhileBlocked = monitor.model(for: .codex, fallback: frozen)
            #expect(!monitor.isManualRefreshInFlight(for: .codex))
            #expect(visibleWhileBlocked.metrics.map(\.percent) == expectedCore.metrics.map(\.percent))
            #expect(visibleWhileBlocked.metrics.map(\.percent) != frozen.metrics.map(\.percent))
            self.emitProbe(
                "compatible enrichment=blocked refreshing=false before=" +
                    "\(frozen.metrics.first?.percentLabel ?? "none") core=" +
                    "\(visibleWhileBlocked.metrics.first?.percentLabel ?? "none")")

            releaseCredits.resume()
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
            updatedAt: updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "fixture@example.com",
                accountOrganization: nil,
                loginMethod: "pro"))
    }

    private func emitProbe(_ line: String) {
        guard ProcessInfo.processInfo.environment["CODEXBAR_REFRESH_PROBE"] == "1" else { return }
        let data = Data("CODEXBAR_REFRESH_PROBE \(line)\n".utf8)
        FileHandle.standardError.write(data)
    }
}
