import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension CodexAccountScopedRefreshTests {
    @Test
    func `dashboard refresh accepted via unresolved routing fallback during account scoped refresh`() async {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-dashboard-unresolved-routing-fallback")
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dashboard-unresolved-routing-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .auto
        settings.codexActiveSource = .liveSystem
        settings._test_liveSystemCodexAccount = nil
        settings._test_codexReconciliationEnvironment = ["CODEX_HOME": isolatedHome.path]
        defer {
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: isolatedHome)
        }

        let store = self.makeUsageStore(settings: settings)
        store.lastKnownLiveSystemCodexEmail = nil
        self.installImmediateCodexProvider(
            on: store,
            snapshot: self.codexSnapshot(email: "work@company.com", usedPercent: 12))
        store._test_codexCreditsLoaderOverride = { self.credits(remaining: 55) }
        defer { store._test_codexCreditsLoaderOverride = nil }

        var observedTargetEmail: String?
        store._test_openAIDashboardLoaderOverride = { accountEmail, _, _ in
            observedTargetEmail = accountEmail
            #expect(store.currentCodexOpenAIWebRefreshGuard().source == .liveSystem)
            #expect(store.currentCodexOpenAIWebRefreshGuard().identity == .unresolved)
            return self.dashboard(email: "work@company.com", creditsRemaining: 33, usedPercent: 12)
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }

        await store.refreshCodexAccountScopedState(allowDisabled: true)

        #expect(observedTargetEmail == "work@company.com")
        #expect(store.currentCodexOpenAIWebRefreshGuard().identity == .unresolved)
        #expect(store.openAIDashboard?.signedInEmail == "work@company.com")
        #expect(store.lastOpenAIDashboardSnapshot?.signedInEmail == "work@company.com")
        #expect(store.openAIDashboardRequiresLogin == false)
        #expect(store.lastOpenAIDashboardError == nil)
        #expect(store.snapshots[.codex]?.accountEmail(for: .codex) == "work@company.com")
        #expect(store.lastSourceLabels[.codex] == "test-codex")
        #expect(store.credits?.remaining == 55)
        #expect(store.lastCreditsSource == .api)
    }

    @Test
    func `dashboard fail closed clears dashboard derived usage credits cache and visible dashboard`() async throws {
        OpenAIDashboardCacheStore.clear()
        defer { OpenAIDashboardCacheStore.clear() }

        let settings = self.makeSettingsStore(suite: "CodexAccountScopedRefreshTests-dashboard-fail-closed-cleanup")
        let managedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedHome) }
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "managed@example.com",
            plan: "pro",
            accountId: "acct-managed")

        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let managedStoreURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_activeManagedCodexAccount = nil
            try? FileManager.default.removeItem(at: managedStoreURL)
        }

        settings.refreshFrequency = .manual
        settings.codexCookieSource = .auto
        settings._test_managedCodexAccountStoreURL = managedStoreURL
        settings._test_activeManagedCodexAccount = managedAccount
        settings.codexActiveSource = .managedAccount(id: managedAccount.id)

        let store = self.makeUsageStore(settings: settings)
        store._setSnapshotForTesting(
            self.codexSnapshot(email: "managed@example.com", usedPercent: 20),
            provider: .codex)
        store.lastSourceLabels[.codex] = "openai-web"
        let staleCredits = self.credits(remaining: 20)
        store.credits = staleCredits
        store.lastCreditsSnapshot = staleCredits
        store.lastCreditsSnapshotAccountKey = "managed@example.com"
        store.lastCreditsSource = .dashboardWeb
        store.openAIDashboard = self.dashboard(email: "managed@example.com", creditsRemaining: 20, usedPercent: 20)
        store.lastOpenAIDashboardSnapshot = store.openAIDashboard
        OpenAIDashboardCacheStore.save(OpenAIDashboardCache(
            accountEmail: "managed@example.com",
            snapshot: self.dashboard(email: "managed@example.com", creditsRemaining: 20, usedPercent: 20)))

        await store.applyOpenAIDashboard(
            self.dashboard(email: "other@example.com", creditsRemaining: 9, usedPercent: 35),
            targetEmail: "managed@example.com")

        #expect(store.openAIDashboard == nil)
        #expect(store.lastOpenAIDashboardSnapshot == nil)
        #expect(store.snapshots[.codex] == nil)
        #expect(store.credits == nil)
        #expect(store.lastCreditsSource == .none)
        #expect(OpenAIDashboardCacheStore.load() == nil)
        #expect(store.openAIDashboardRequiresLogin == true)
        #expect(store.lastOpenAIDashboardError?.contains("OpenAI dashboard signed in as other@example.com") == true)
    }
}
