import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
@MainActor
struct CodexManagedOpenAIWebTests {
    @Test
    func `managed codex open A I web uses active managed identity and cache scope`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let settings = self.makeSettingsStore(suite: "CodexManagedOpenAIWebTests-managed")
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-codex-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        settings._test_activeManagedCodexAccount = managedAccount
        defer { settings._test_activeManagedCodexAccount = nil }

        let otherAccountID = UUID()
        CookieHeaderCache.store(
            provider: .codex,
            scope: .managedAccount(otherAccountID),
            cookieHeader: "auth=other-account",
            sourceLabel: "Chrome")
        CookieHeaderCache.store(
            provider: .codex,
            cookieHeader: "auth=provider-global",
            sourceLabel: "Safari")
        defer {
            CookieHeaderCache.clear(provider: .codex, scope: .managedAccount(otherAccountID))
            CookieHeaderCache.clear(provider: .codex)
        }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)

        #expect(store.codexAccountEmailForOpenAIDashboard() == "managed@example.com")
        #expect(store.codexCookieCacheScopeForOpenAIWeb() == .managedAccount(managedAccount.id))
        #expect(CookieHeaderCache.load(provider: .codex, scope: store.codexCookieCacheScopeForOpenAIWeb()) == nil)
    }

    @Test
    func `unmanaged codex open A I web falls back to provider global cache scope`() {
        let settings = self.makeSettingsStore(suite: "CodexManagedOpenAIWebTests-unmanaged")
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)

        #expect(store.codexCookieCacheScopeForOpenAIWeb() == nil)
    }

    @Test
    func `unreadable managed codex store fails closed for open A I web`() async {
        let settings = self.makeSettingsStore(suite: "CodexManagedOpenAIWebTests-unreadable-store")
        settings._test_unreadableManagedCodexAccountStore = true
        defer { settings._test_unreadableManagedCodexAccountStore = false }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)

        #expect(store.codexCookieCacheScopeForOpenAIWeb() == .managedStoreUnreadable)
        #expect(store.codexAccountEmailForOpenAIDashboard() == nil)

        let imported = await store.importOpenAIDashboardCookiesIfNeeded(targetEmail: nil, force: true)

        #expect(imported == nil)
        #expect(store.openAIDashboard == nil)
        #expect(store.openAIDashboardRequiresLogin == true)
        #expect(store.openAIDashboardCookieImportStatus?.contains("Managed Codex account data is unavailable") == true)

        await store.refreshOpenAIDashboardIfNeeded(force: true)

        #expect(store.openAIDashboard == nil)
        #expect(store.openAIDashboardRequiresLogin == true)
        #expect(store.lastOpenAIDashboardError?.contains("Managed Codex account data is unavailable") == true)
    }

    @Test
    func `managed codex mismatch fail closed blocks stale dashboard restoration`() async {
        let settings = self.makeSettingsStore(suite: "CodexManagedOpenAIWebTests-mismatch")
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-codex-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        settings._test_activeManagedCodexAccount = managedAccount
        defer { settings._test_activeManagedCodexAccount = nil }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let staleSnapshot = OpenAIDashboardSnapshot(
            signedInEmail: managedAccount.email,
            codeReviewRemainingPercent: 100,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: Date())

        await store.applyOpenAIDashboard(staleSnapshot, targetEmail: managedAccount.email)
        await store.applyOpenAIDashboardMismatchFailure(
            signedInEmail: "other@example.com",
            expectedEmail: managedAccount.email)

        #expect(store.openAIDashboard == nil)
        #expect(store.openAIDashboardRequiresLogin == true)

        await store.applyOpenAIDashboardFailure(message: "No dashboard data")
        #expect(store.openAIDashboard == nil)
        #expect(store.lastOpenAIDashboardError == "No dashboard data")

        await store.applyOpenAIDashboardLoginRequiredFailure()
        #expect(store.openAIDashboard == nil)
        #expect(store.openAIDashboardRequiresLogin == true)
        #expect(store.lastOpenAIDashboardError?.contains("requires a signed-in chatgpt.com session") == true)
    }

    @Test
    func `managed codex import mismatch fail closed blocks stale dashboard restoration`() async {
        let settings = self.makeSettingsStore(suite: "CodexManagedOpenAIWebTests-import-mismatch")
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-codex-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        settings._test_activeManagedCodexAccount = managedAccount
        defer { settings._test_activeManagedCodexAccount = nil }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store._test_openAIDashboardCookieImportOverride = { _, _, _, _, _ in
            throw OpenAIDashboardBrowserCookieImporter.ImportError.noMatchingAccount(
                found: [.init(sourceLabel: "Chrome", email: "other@example.com")])
        }

        let staleSnapshot = OpenAIDashboardSnapshot(
            signedInEmail: managedAccount.email,
            codeReviewRemainingPercent: 100,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: Date())
        await store.applyOpenAIDashboard(staleSnapshot, targetEmail: managedAccount.email)

        let imported = await store.importOpenAIDashboardCookiesIfNeeded(
            targetEmail: managedAccount.email,
            force: true)

        #expect(imported == nil)
        #expect(store.openAIDashboard == nil)
        #expect(store.openAIDashboardRequiresLogin == true)
        #expect(store.openAIDashboardCookieImportStatus?.contains("do not match Codex account") == true)

        await store.applyOpenAIDashboardFailure(message: "No dashboard data")
        #expect(store.openAIDashboard == nil)
        #expect(store.lastOpenAIDashboardError == "No dashboard data")

        await store.applyOpenAIDashboardLoginRequiredFailure()
        #expect(store.openAIDashboard == nil)
        #expect(store.openAIDashboardRequiresLogin == true)
        #expect(store.lastOpenAIDashboardError?.contains("requires a signed-in chatgpt.com session") == true)
    }

    private func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }
}
