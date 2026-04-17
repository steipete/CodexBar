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
        settings.codexActiveSource = .managedAccount(id: managedAccount.id)
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
    func `managed codex open A I web targets runtime auth backed email for selected account`() throws {
        let settings = self.makeSettingsStore(suite: "CodexManagedOpenAIWebTests-managed-runtime-email")
        let managedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedHome) }
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "renamed@example.com",
            plan: "pro",
            accountId: "acct-managed")

        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "legacy@example.com",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        settings._test_activeManagedCodexAccount = managedAccount
        settings.codexActiveSource = .managedAccount(id: managedAccount.id)
        defer { settings._test_activeManagedCodexAccount = nil }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)

        #expect(store.codexAccountEmailForOpenAIDashboard() == "renamed@example.com")
        #expect(store.codexAccountEmailForOpenAIDashboard() != managedAccount.email)
        #expect(store.currentCodexOpenAIWebRefreshGuard().accountKey == "renamed@example.com")
        #expect(store.currentCodexOpenAIWebRefreshGuard().identity == .providerAccount(id: "acct-managed"))
    }

    @Test
    func `live system codex open A I web uses live identity and no managed cache scope`() {
        let settings = self.makeSettingsStore(suite: "CodexManagedOpenAIWebTests-live-system")
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-codex-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let liveAccount = ObservedSystemCodexAccount(
            email: "system@example.com",
            codexHomePath: "/tmp/live-codex-home",
            observedAt: Date())
        settings._test_activeManagedCodexAccount = managedAccount
        settings._test_liveSystemCodexAccount = liveAccount
        settings.codexActiveSource = .liveSystem
        defer {
            settings._test_activeManagedCodexAccount = nil
            settings._test_liveSystemCodexAccount = nil
        }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: ["CODEX_HOME": liveAccount.codexHomePath]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)

        #expect(store.codexAccountEmailForOpenAIDashboard() == liveAccount.email)
        #expect(store.codexAccountEmailForOpenAIDashboard() != managedAccount.email)
        #expect(store.codexCookieCacheScopeForOpenAIWeb() == nil)
    }

    @Test
    func `live system codex open A I web does not reuse stale managed snapshot email after source switch`() {
        let settings = self.makeSettingsStore(suite: "CodexManagedOpenAIWebTests-live-system-stale-managed-snapshot")
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-openai-web-empty-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-codex-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)

        settings._test_activeManagedCodexAccount = managedAccount
        settings._test_codexReconciliationEnvironment = ["CODEX_HOME": isolatedHome.path]
        settings.codexActiveSource = .liveSystem
        defer {
            settings._test_activeManagedCodexAccount = nil
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: isolatedHome)
        }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: nil,
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: managedAccount.email,
                    accountOrganization: nil,
                    loginMethod: nil)),
            provider: .codex)

        #expect(store.codexAccountEmailForOpenAIDashboard() == nil)
        #expect(store.codexAccountEmailForOpenAIDashboard() != managedAccount.email)
        #expect(store.codexCookieCacheScopeForOpenAIWeb() == nil)
    }

    @Test
    func `live system codex open A I web reuses last known live email without allowing any account`() async {
        let settings = self.makeSettingsStore(suite: "CodexManagedOpenAIWebTests-live-system-last-known-email")
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-openai-web-last-known-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let liveAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/tmp/live-codex-home",
            observedAt: Date())
        settings._test_liveSystemCodexAccount = liveAccount
        settings._test_codexReconciliationEnvironment = ["CODEX_HOME": isolatedHome.path]
        settings.codexActiveSource = .liveSystem

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)

        #expect(store.codexAccountEmailForOpenAIDashboard() == liveAccount.email)

        settings._test_liveSystemCodexAccount = nil
        defer {
            settings._test_liveSystemCodexAccount = nil
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: isolatedHome)
        }

        store.openAIDashboard = OpenAIDashboardSnapshot(
            signedInEmail: "managed@example.com",
            codeReviewRemainingPercent: 100,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: Date())
        store.lastOpenAIDashboardCookieImportEmail = "managed-import@example.com"

        var observedTargetEmail: String?
        var observedAllowAnyAccount: Bool?
        store._test_openAIDashboardCookieImportOverride = { targetEmail, allowAnyAccount, _, _, _ in
            observedTargetEmail = targetEmail
            observedAllowAnyAccount = allowAnyAccount
            return OpenAIDashboardBrowserCookieImporter.ImportResult(
                sourceLabel: "test",
                cookieCount: 1,
                signedInEmail: targetEmail,
                matchesCodexEmail: true)
        }
        defer { store._test_openAIDashboardCookieImportOverride = nil }

        let targetEmail = store.codexAccountEmailForOpenAIDashboard()
        let imported = await store.importOpenAIDashboardCookiesIfNeeded(targetEmail: targetEmail, force: true)

        #expect(targetEmail == liveAccount.email)
        #expect(targetEmail != "managed@example.com")
        #expect(targetEmail != "managed-import@example.com")
        #expect(imported == liveAccount.email)
        #expect(observedTargetEmail == liveAccount.email)
        #expect(observedAllowAnyAccount == false)
    }

    @Test
    func `successful dashboard apply preserves cached open A I web view for same account`() async {
        let settings = self.makeSettingsStore(suite: "CodexManagedOpenAIWebTests-preserve-cache-on-success")
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-codex-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        settings._test_activeManagedCodexAccount = managedAccount
        settings.codexActiveSource = .managedAccount(id: managedAccount.id)
        defer { settings._test_activeManagedCodexAccount = nil }

        OpenAIDashboardWebsiteDataStore.clearCacheForTesting()
        let cache = OpenAIDashboardWebViewCache.shared
        cache.clearAllForTesting()
        defer {
            cache.clearAllForTesting()
            OpenAIDashboardWebsiteDataStore.clearCacheForTesting()
        }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let websiteDataStore = OpenAIDashboardWebsiteDataStore.store(forAccountEmail: managedAccount.email)
        cache.cacheEntryForTesting(websiteDataStore: websiteDataStore)

        #expect(cache.hasCachedEntry(for: websiteDataStore))

        await store.applyOpenAIDashboard(
            OpenAIDashboardSnapshot(
                signedInEmail: managedAccount.email,
                codeReviewRemainingPercent: 90,
                creditEvents: [],
                dailyBreakdown: [],
                usageBreakdown: [],
                creditsPurchaseURL: nil,
                creditsRemaining: 10,
                accountPlan: "Pro",
                updatedAt: Date()),
            targetEmail: managedAccount.email)

        #expect(cache.hasCachedEntry(for: websiteDataStore))
        #expect(cache.entryCount == 1)
    }

    @Test
    func `dashboard refresh does not target stale last known live email`() async {
        let settings = self.makeSettingsStore(suite: "CodexManagedOpenAIWebTests-live-system-refresh-strict-target")
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-openai-web-refresh-strict-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        let liveAccount = ObservedSystemCodexAccount(
            email: "old@example.com",
            codexHomePath: "/tmp/live-codex-home",
            observedAt: Date())
        settings._test_liveSystemCodexAccount = liveAccount
        settings._test_codexReconciliationEnvironment = ["CODEX_HOME": isolatedHome.path]
        settings.codexActiveSource = .liveSystem

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)

        #expect(store.codexAccountEmailForOpenAIDashboard() == liveAccount.email)

        settings._test_liveSystemCodexAccount = nil
        defer {
            settings._test_liveSystemCodexAccount = nil
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: isolatedHome)
        }

        var observedTargetEmail: String?
        store._test_openAIDashboardLoaderOverride = { accountEmail, _, _ in
            observedTargetEmail = accountEmail
            return OpenAIDashboardSnapshot(
                signedInEmail: "new@example.com",
                codeReviewRemainingPercent: 88,
                creditEvents: [],
                dailyBreakdown: [],
                usageBreakdown: [],
                creditsPurchaseURL: nil,
                primaryLimit: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondaryLimit: nil,
                creditsRemaining: 22,
                accountPlan: "Pro",
                updatedAt: Date())
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }

        let expectedGuard = store.currentCodexOpenAIWebRefreshGuard()
        #expect(expectedGuard.accountKey == nil)

        await store.refreshOpenAIDashboardIfNeeded(force: true, expectedGuard: expectedGuard)

        #expect(observedTargetEmail == nil)
        #expect(store.openAIDashboard == nil)
        #expect(store.openAIDashboardRequiresLogin == true)
        #expect(store.lastOpenAIDashboardError?.contains("could not be verified") == true)
        #expect(store.lastKnownLiveSystemCodexEmail == "old@example.com")
    }

    @Test
    func `dashboard refresh targets usage discovered live email before reconciliation catches up`() async {
        let settings = self.makeSettingsStore(suite: "CodexManagedOpenAIWebTests-live-system-usage-discovered-target")
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-openai-web-usage-discovered-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        settings._test_codexReconciliationEnvironment = ["CODEX_HOME": isolatedHome.path]
        settings.codexActiveSource = .liveSystem
        defer {
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: isolatedHome)
        }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: nil,
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "usage@example.com",
                    accountOrganization: nil,
                    loginMethod: nil)),
            provider: .codex)
        store.lastSourceLabels[.codex] = "codex-cli"

        var observedTargetEmail: String?
        store._test_openAIDashboardLoaderOverride = { accountEmail, _, _ in
            observedTargetEmail = accountEmail
            return OpenAIDashboardSnapshot(
                signedInEmail: "usage@example.com",
                codeReviewRemainingPercent: 88,
                creditEvents: [],
                dailyBreakdown: [],
                usageBreakdown: [],
                creditsPurchaseURL: nil,
                primaryLimit: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondaryLimit: nil,
                creditsRemaining: 22,
                accountPlan: "Pro",
                updatedAt: Date())
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }

        let expectedGuard = store.currentCodexOpenAIWebRefreshGuard()
        #expect(expectedGuard.accountKey == nil)

        await store.refreshOpenAIDashboardIfNeeded(force: true, expectedGuard: expectedGuard)

        #expect(observedTargetEmail == "usage@example.com")
        #expect(store.openAIDashboard?.signedInEmail == "usage@example.com")
    }

    @Test
    func `usage discovered live email still surfaces open A I web login guidance during reconciliation lag`() async {
        let settings = self.makeSettingsStore(suite: "CodexManagedOpenAIWebTests-live-system-usage-discovered-failure")
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-openai-web-usage-discovered-failure-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        settings._test_codexReconciliationEnvironment = ["CODEX_HOME": isolatedHome.path]
        settings.codexActiveSource = .liveSystem
        defer {
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: isolatedHome)
        }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: nil,
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "usage@example.com",
                    accountOrganization: nil,
                    loginMethod: nil)),
            provider: .codex)
        store.lastSourceLabels[.codex] = "codex-cli"

        let expectedGuard = store.currentCodexOpenAIWebRefreshGuard()
        #expect(expectedGuard.accountKey == nil)

        await store.applyOpenAIDashboardLoginRequiredFailure(
            expectedGuard: expectedGuard,
            routingTargetEmail: "usage@example.com")

        #expect(store.openAIDashboardRequiresLogin == true)
        #expect(store.lastOpenAIDashboardError?.contains("requires a signed-in chatgpt.com session") == true)
    }

    @Test
    func `open A I web import uses managed account target when live account differs`() async {
        let settings = self.makeSettingsStore(suite: "CodexManagedOpenAIWebTests-targeting-active-vs-live")
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-codex-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let liveAccount = ObservedSystemCodexAccount(
            email: "system@example.com",
            codexHomePath: "/tmp/live-codex-home",
            observedAt: Date())
        let expectedScope = CookieHeaderCache.Scope.managedAccount(managedAccount.id)
        let expectedEmail = managedAccount.email
        var observedTargetEmail: String?
        var observedScope: CookieHeaderCache.Scope?
        var observedCookieSource: ProviderCookieSource?
        var observedAllowAnyAccount = false

        settings._test_activeManagedCodexAccount = managedAccount
        settings._test_liveSystemCodexAccount = liveAccount
        settings.codexActiveSource = .managedAccount(id: managedAccount.id)
        defer {
            settings._test_activeManagedCodexAccount = nil
            settings._test_liveSystemCodexAccount = nil
        }

        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: liveAccount.email,
                accountOrganization: nil,
                loginMethod: nil))

        let store = UsageStore(
            fetcher: UsageFetcher(environment: ["CODEX_HOME": liveAccount.codexHomePath]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._test_openAIDashboardCookieImportOverride = { targetEmail, allowAnyAccount, cookieSource, scope, _ in
            observedTargetEmail = targetEmail
            observedScope = scope
            observedCookieSource = cookieSource
            observedAllowAnyAccount = allowAnyAccount
            return OpenAIDashboardBrowserCookieImporter.ImportResult(
                sourceLabel: "test",
                cookieCount: 1,
                signedInEmail: targetEmail,
                matchesCodexEmail: targetEmail == expectedEmail)
        }
        defer { store._test_openAIDashboardCookieImportOverride = nil }

        let importerTarget = store.codexAccountEmailForOpenAIDashboard()
        let imported = await store.importOpenAIDashboardCookiesIfNeeded(targetEmail: importerTarget, force: true)

        #expect(importerTarget == expectedEmail)
        #expect(importerTarget != liveAccount.email)
        #expect(imported == expectedEmail)
        #expect(observedTargetEmail == expectedEmail)
        #expect(observedScope == expectedScope)
        #expect(observedAllowAnyAccount == false)
        #expect(observedCookieSource == .auto)
        #expect(store.codexCookieCacheScopeForOpenAIWeb() == expectedScope)
    }

    @Test
    func `open A I web prefers live identity when managed and live share email`() {
        let settings = self.makeSettingsStore(suite: "CodexManagedOpenAIWebTests-same-email-prefers-live")
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "person@example.com",
            managedHomePath: "/tmp/managed-codex-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let liveAccount = ObservedSystemCodexAccount(
            email: "PERSON@example.com",
            codexHomePath: "/tmp/live-codex-home",
            observedAt: Date())
        settings._test_activeManagedCodexAccount = managedAccount
        settings._test_liveSystemCodexAccount = liveAccount
        settings.codexActiveSource = .managedAccount(id: managedAccount.id)
        defer {
            settings._test_activeManagedCodexAccount = nil
            settings._test_liveSystemCodexAccount = nil
        }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: ["CODEX_HOME": liveAccount.codexHomePath]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)

        #expect(settings.codexResolvedActiveSource == .liveSystem)
        #expect(store.codexAccountEmailForOpenAIDashboard() == "person@example.com")
        #expect(store.codexCookieCacheScopeForOpenAIWeb() == nil)
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
        settings.codexActiveSource = .managedAccount(id: UUID())
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
    func `missing managed codex open A I web target fails closed`() async {
        let settings = self.makeSettingsStore(suite: "CodexManagedOpenAIWebTests-missing-managed-target")
        let storedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "stored@example.com",
            managedHomePath: "/tmp/stored-managed-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-openai-web-\(UUID().uuidString).json")
        let managedStore = FileManagedCodexAccountStore(fileURL: storeURL)
        try? managedStore.storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [storedAccount]))
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: UUID())
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
        }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        var importWasCalled = false
        store._test_openAIDashboardCookieImportOverride = { _, _, _, _, _ in
            importWasCalled = true
            return OpenAIDashboardBrowserCookieImporter.ImportResult(
                sourceLabel: "test",
                cookieCount: 1,
                signedInEmail: "unexpected@example.com",
                matchesCodexEmail: true)
        }
        defer { store._test_openAIDashboardCookieImportOverride = nil }
        store.openAIDashboard = OpenAIDashboardSnapshot(
            signedInEmail: "stale-dashboard@example.com",
            codeReviewRemainingPercent: 100,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: Date())
        store.lastOpenAIDashboardCookieImportEmail = "stale-import@example.com"

        #expect(store.codexAccountEmailForOpenAIDashboard() == nil)
        #expect(store.codexCookieCacheScopeForOpenAIWeb() != nil)
        #expect(store.codexCookieCacheScopeForOpenAIWeb() != .managedStoreUnreadable)

        let imported = await store.importOpenAIDashboardCookiesIfNeeded(targetEmail: nil, force: true)
        #expect(imported == nil)
        #expect(importWasCalled == false)
        #expect(store.openAIDashboard == nil)
        #expect(store.openAIDashboardRequiresLogin == true)
        #expect(store.openAIDashboardCookieImportStatus?
            .contains("selected managed Codex account is unavailable") == true)

        await store.refreshOpenAIDashboardIfNeeded(force: true)
        #expect(importWasCalled == false)
        #expect(store.openAIDashboard == nil)
        #expect(store.lastOpenAIDashboardError?.contains("selected managed Codex account is unavailable") == true)
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
        settings.codexActiveSource = .managedAccount(id: managedAccount.id)
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
        await store.applyOpenAIDashboard(
            OpenAIDashboardSnapshot(
                signedInEmail: "other@example.com",
                codeReviewRemainingPercent: 100,
                creditEvents: [],
                dailyBreakdown: [],
                usageBreakdown: [],
                creditsPurchaseURL: nil,
                updatedAt: Date()),
            targetEmail: managedAccount.email)

        #expect(store.openAIDashboard == nil)
        #expect(store.lastOpenAIDashboardSnapshot == nil)
        #expect(store.openAIDashboardRequiresLogin == true)
        #expect(store.lastOpenAIDashboardError?.contains("OpenAI dashboard signed in as other@example.com") == true)

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
        #expect(
            store.openAIDashboardCookieImportStatus ==
                "OpenAI cookies are for other@example.com, not managed@example.com.")

        await store.applyOpenAIDashboardFailure(message: "No dashboard data")
        #expect(store.openAIDashboard == nil)
        #expect(store.lastOpenAIDashboardError == "No dashboard data")

        await store.applyOpenAIDashboardLoginRequiredFailure()
        #expect(store.openAIDashboard == nil)
        #expect(store.openAIDashboardRequiresLogin == true)
        #expect(store.lastOpenAIDashboardError?.contains("requires a signed-in chatgpt.com session") == true)
    }

    @Test
    func `missing managed target failure handlers do not resurrect stale dashboard state`() async {
        let settings = self.makeSettingsStore(suite: "CodexManagedOpenAIWebTests-missing-target-failure-handlers")
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-openai-web-missing-target-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        settings._test_codexReconciliationEnvironment = ["CODEX_HOME": isolatedHome.path]
        settings.codexActiveSource = .managedAccount(id: UUID())
        defer {
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: isolatedHome)
        }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let staleSnapshot = OpenAIDashboardSnapshot(
            signedInEmail: "stale@example.com",
            codeReviewRemainingPercent: 100,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: Date())

        await store.applyOpenAIDashboard(staleSnapshot, targetEmail: "stale@example.com")
        await store.applyOpenAIDashboardFailure(message: "No dashboard data")

        #expect(store.openAIDashboard == nil)
        #expect(store.lastOpenAIDashboardSnapshot == nil)
        #expect(store.lastOpenAIDashboardError?.contains("selected managed Codex account is unavailable") == true)

        await store.applyOpenAIDashboard(staleSnapshot, targetEmail: "stale@example.com")
        await store.applyOpenAIDashboardLoginRequiredFailure()

        #expect(store.openAIDashboard == nil)
        #expect(store.lastOpenAIDashboardSnapshot == nil)
        #expect(store.openAIDashboardRequiresLogin == true)
        #expect(store.lastOpenAIDashboardError?.contains("selected managed Codex account is unavailable") == true)
    }

    @Test
    func `managed codex refresh stops after cookie mismatch instead of retrying web view`() async {
        let settings = self.makeSettingsStore(suite: "CodexManagedOpenAIWebTests-mismatch-aborts-retry")
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "ratulsarna@gmail.com",
            managedHomePath: "/tmp/managed-codex-home",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        settings._test_activeManagedCodexAccount = managedAccount
        settings.codexActiveSource = .managedAccount(id: managedAccount.id)
        defer { settings._test_activeManagedCodexAccount = nil }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)

        var loaderCalls = 0
        store._test_openAIDashboardLoaderOverride = { _, _, _ in
            loaderCalls += 1
            throw OpenAIDashboardFetcher.FetchError.loginRequired
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }
        store._test_openAIDashboardCookieImportOverride = { _, _, _, _, _ in
            throw OpenAIDashboardBrowserCookieImporter.ImportError.noMatchingAccount(
                found: [.init(sourceLabel: "Chrome", email: "rdsarna@gmail.com")])
        }
        defer { store._test_openAIDashboardCookieImportOverride = nil }

        let expectedGuard = store.currentCodexOpenAIWebRefreshGuard()
        await store.refreshOpenAIDashboardIfNeeded(force: true, expectedGuard: expectedGuard)

        #expect(loaderCalls == 1)
        #expect(
            store.lastOpenAIDashboardError ==
                "OpenAI cookies are for rdsarna@gmail.com, not ratulsarna@gmail.com. " +
                "Switch chatgpt.com account, then refresh OpenAI cookies.")
        #expect(store.openAIDashboard == nil)
    }
}
