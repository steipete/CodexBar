import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `same account token refresh fingerprint change keeps codex usage success`() async {
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-token-refresh-fingerprint-change")
        defer {
            SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = nil
            settings._test_liveSystemCodexAccount = nil
        }
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "old-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))
        let staleReconciliationSnapshot = settings.codexAccountReconciliationSnapshot

        let store = self.makeUsageStore(settings: settings)
        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        await blocker.waitUntilStarted()
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "new-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))
        settings.cachedCodexAccountReconciliationSnapshot = CachedCodexAccountReconciliationSnapshot(
            activeSource: .liveSystem,
            loadedAt: Date(),
            snapshot: staleReconciliationSnapshot)
        await blocker.resume(with: .success(self.codexSnapshot(email: "alpha@example.com", usedPercent: 25)))
        await refreshTask.value

        #expect(store.snapshots[.codex]?.primary?.usedPercent == 25)
        #expect(store.lastCodexAccountScopedRefreshGuard?.authFingerprint == "new-token-material")
        #expect(store.errors[.codex] == nil)
    }

    @Test
    func `same account token refresh fingerprint change keeps reset backfill`() async {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-token-refresh-reset-backfill")
        defer {
            settings._test_liveSystemCodexAccount = nil
        }
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "old-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))
        let store = self.makeUsageStore(settings: settings)
        let resetsAt = Date().addingTimeInterval(45 * 60)
        store.lastCodexAccountScopedRefreshGuard = store.freshCodexAccountScopedRefreshGuard()
        store.lastKnownResetSnapshots[.codex] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 10,
                windowMinutes: 300,
                resetsAt: resetsAt,
                resetDescription: "resets soon"),
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "alpha@example.com",
                accountOrganization: nil,
                loginMethod: "Pro"))
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "new-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))
        self.installImmediateCodexProvider(
            on: store,
            snapshot: self.codexSnapshot(email: "alpha@example.com", usedPercent: 25))

        await store.refreshProvider(.codex, allowDisabled: true)

        #expect(store.snapshots[.codex]?.primary?.usedPercent == 25)
        #expect(store.snapshots[.codex]?.primary?.resetsAt == resetsAt)
        #expect(store.lastKnownResetSnapshots[.codex]?.primary?.resetsAt == resetsAt)
        #expect(store.lastCodexAccountScopedRefreshGuard?.authFingerprint == "new-token-material")
    }

    @Test
    func `same account token refresh fingerprint change keeps scoped state during prepare`() {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-token-refresh-prepare")
        defer {
            settings._test_liveSystemCodexAccount = nil
        }
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "old-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))
        let store = self.makeUsageStore(settings: settings)
        let resetsAt = Date().addingTimeInterval(45 * 60)
        let cached = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 10,
                windowMinutes: 300,
                resetsAt: resetsAt,
                resetDescription: "resets soon"),
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "alpha@example.com",
                accountOrganization: nil,
                loginMethod: "Pro"))
        store.snapshots[.codex] = cached
        store.lastKnownResetSnapshots[.codex] = cached
        store.credits = self.credits(remaining: 42)
        store.lastCodexAccountScopedRefreshGuard = store.freshCodexAccountScopedRefreshGuard()
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "new-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))

        let invalidated = store.prepareCodexAccountScopedRefreshIfNeeded()

        #expect(!invalidated)
        #expect(store.snapshots[.codex]?.primary?.resetsAt == resetsAt)
        #expect(store.lastKnownResetSnapshots[.codex]?.primary?.resetsAt == resetsAt)
        #expect(store.credits?.remaining == 42)
        #expect(store.lastCodexAccountScopedRefreshGuard?.authFingerprint == "new-token-material")
    }

    @Test
    func `usage success applies when auth fingerprint appears after refresh starts`() {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-auth-fingerprint-appears")
        defer {
            settings._test_liveSystemCodexAccount = nil
        }
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: nil,
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "alpha@example.com"))
        let store = self.makeUsageStore(settings: settings)
        let expectedGuard = store.freshCodexAccountScopedRefreshGuard()

        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "new-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "alpha@example.com"))

        #expect(store.shouldApplyCodexUsageResult(
            expectedGuard: expectedGuard,
            usage: self.codexSnapshot(email: "alpha@example.com", usedPercent: 25)))
    }

    @Test
    func `same account token refresh fingerprint change discards codex usage failure`() async {
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-token-refresh-fingerprint-failure")
        defer {
            SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = nil
            settings._test_liveSystemCodexAccount = nil
        }
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "old-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))
        let staleReconciliationSnapshot = settings.codexAccountReconciliationSnapshot

        let store = self.makeUsageStore(settings: settings)
        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        await blocker.waitUntilStarted()
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "new-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))
        settings.cachedCodexAccountReconciliationSnapshot = CachedCodexAccountReconciliationSnapshot(
            activeSource: .liveSystem,
            loadedAt: Date(),
            snapshot: staleReconciliationSnapshot)
        await blocker.resume(with: .failure(TestRefreshError(message: "old token failure")))
        await refreshTask.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.errors[.codex] == nil)
    }

    @Test
    func `same account token refresh fingerprint change keeps codex credits success`() async {
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-token-refresh-credits-success")
        defer {
            SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = nil
            settings._test_liveSystemCodexAccount = nil
        }
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "old-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))

        let store = self.makeUsageStore(settings: settings)
        store._test_codexCreditsLoaderOverride = {
            settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
                email: "alpha@example.com",
                authFingerprint: "new-token-material",
                codexHomePath: "/Users/test/.codex",
                observedAt: Date(),
                identity: .providerAccount(id: "acct-alpha"))
            return CreditsSnapshot(remaining: 42, events: [], updatedAt: Date())
        }
        defer { store._test_codexCreditsLoaderOverride = nil }

        await store.refreshCreditsIfNeeded()

        #expect(store.credits?.remaining == 42)
        #expect(store.lastCreditsSnapshotAccountKey == "alpha@example.com")
        #expect(store.lastCodexAccountScopedRefreshGuard?.authFingerprint == "new-token-material")
        #expect(store.lastCreditsError == nil)
    }

    @Test
    func `credits refresh key separates same account auth fingerprints`() {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-credits-key-auth-fingerprint")
        let store = self.makeUsageStore(settings: settings)
        let oldGuard = CodexAccountScopedRefreshGuard(
            source: .liveSystem,
            identity: .providerAccount(id: "acct-alpha"),
            accountKey: "alpha@example.com",
            authFingerprint: "old-token-material")
        let newGuard = CodexAccountScopedRefreshGuard(
            source: .liveSystem,
            identity: .providerAccount(id: "acct-alpha"),
            accountKey: "alpha@example.com",
            authFingerprint: "new-token-material")

        #expect(store.codexCreditsRefreshKey(expectedGuard: oldGuard) !=
            store.codexCreditsRefreshKey(expectedGuard: newGuard))
    }

    @Test
    func `same account token refresh fingerprint change keeps dashboard success`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-token-refresh-dashboard-success")
        let codexMetadata = try #require(ProviderDescriptorRegistry.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: codexMetadata, enabled: true)
        settings.refreshFrequency = .manual
        settings.openAIWebAccessEnabled = true
        settings.codexCookieSource = .auto
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "old-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))
        defer {
            settings._test_liveSystemCodexAccount = nil
        }

        let store = self.makeUsageStore(settings: settings)
        let expectedGuard = store.freshCodexOpenAIWebRefreshGuard()
        store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
            settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
                email: "alpha@example.com",
                authFingerprint: "new-token-material",
                codexHomePath: "/Users/test/.codex",
                observedAt: Date(),
                identity: .providerAccount(id: "acct-alpha"))
            return self.dashboard(email: "alpha@example.com", creditsRemaining: 64, usedPercent: 27)
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }

        await store.refreshOpenAIDashboardIfNeeded(force: true, expectedGuard: expectedGuard)

        #expect(store.openAIDashboard?.creditsRemaining == 64)
        #expect(store.openAIDashboard?.signedInEmail == "alpha@example.com")
        #expect(store.lastOpenAIDashboardError == nil)
        #expect(store.openAIDashboardRequiresLogin == false)
    }

    @Test
    func `dashboard refresh key separates same account auth fingerprints`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-dashboard-key-auth-fingerprint")
        let codexMetadata = try #require(ProviderDescriptorRegistry.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: codexMetadata, enabled: true)
        settings.refreshFrequency = .manual
        settings.openAIWebAccessEnabled = true
        settings.codexCookieSource = .auto
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "old-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))
        defer {
            settings._test_liveSystemCodexAccount = nil
        }

        let store = self.makeUsageStore(settings: settings)
        let blocker = BlockingManagedOpenAIDashboardLoader()
        store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
            try await blocker.awaitResult()
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }

        let oldGuard = store.freshCodexOpenAIWebRefreshGuard()
        let oldRefreshTask = Task {
            await store.refreshOpenAIDashboardIfNeeded(force: true, expectedGuard: oldGuard)
        }
        await blocker.waitUntilStarted(count: 1)

        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "new-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))
        let newGuard = store.freshCodexOpenAIWebRefreshGuard()
        let newRefreshTask = Task {
            await store.refreshOpenAIDashboardIfNeeded(force: true, expectedGuard: newGuard)
        }

        let didStartFreshRefresh = await blocker.waitUntilStartedWithin(count: 2)
        #expect(didStartFreshRefresh)
        guard didStartFreshRefresh else {
            await blocker.resumeNext(with: .failure(TestRefreshError(message: "stale dashboard failure")))
            await oldRefreshTask.value
            await newRefreshTask.value
            return
        }
        await blocker.resumeNext(with: .failure(TestRefreshError(message: "old dashboard failure")))
        await blocker.resumeNext(with: .success(self.dashboard(
            email: "alpha@example.com",
            creditsRemaining: 64,
            usedPercent: 27)))
        await oldRefreshTask.value
        await newRefreshTask.value

        #expect(store.openAIDashboard?.creditsRemaining == 64)
        #expect(store.lastOpenAIDashboardError == nil)
    }

    @Test
    func `same account token refresh fingerprint change discards dashboard failure`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-token-refresh-dashboard-failure")
        let codexMetadata = try #require(ProviderDescriptorRegistry.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: codexMetadata, enabled: true)
        settings.refreshFrequency = .manual
        settings.openAIWebAccessEnabled = true
        settings.codexCookieSource = .auto
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "old-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))
        defer {
            settings._test_liveSystemCodexAccount = nil
        }

        let store = self.makeUsageStore(settings: settings)
        let expectedGuard = store.freshCodexOpenAIWebRefreshGuard()
        store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
            settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
                email: "alpha@example.com",
                authFingerprint: "new-token-material",
                codexHomePath: "/Users/test/.codex",
                observedAt: Date(),
                identity: .providerAccount(id: "acct-alpha"))
            throw TestRefreshError(message: "old dashboard failure")
        }
        defer { store._test_openAIDashboardLoaderOverride = nil }

        await store.refreshOpenAIDashboardIfNeeded(force: true, expectedGuard: expectedGuard)

        #expect(store.openAIDashboard == nil)
        #expect(store.lastOpenAIDashboardError == nil)
        #expect(store.openAIDashboardRequiresLogin == false)
    }

    @Test
    func `same account token refresh fingerprint change applies dashboard policy failure`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-token-refresh-dashboard-policy-failure")
        let codexMetadata = try #require(ProviderDescriptorRegistry.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: codexMetadata, enabled: true)
        settings.refreshFrequency = .manual
        settings.openAIWebAccessEnabled = true
        settings.codexCookieSource = .auto
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "old-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))
        defer {
            settings._test_liveSystemCodexAccount = nil
        }

        let store = self.makeUsageStore(settings: settings)
        let expectedGuard = store.freshCodexOpenAIWebRefreshGuard()
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "new-token-material",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-alpha"))

        await store.applyOpenAIDashboard(
            self.dashboard(email: "other@example.com", creditsRemaining: 64, usedPercent: 27),
            targetEmail: "alpha@example.com",
            expectedGuard: expectedGuard)

        #expect(store.openAIDashboard == nil)
        #expect(store.lastOpenAIDashboardError?.contains("OpenAI dashboard signed in as other@example.com") == true)
        #expect(store.openAIDashboardRequiresLogin == true)
    }

    @Test
    func `stacked visible refresh discards selected failure after managed token fingerprint rotates`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-selected-managed-token-failure")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let targetID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-444444444444"))
        let siblingID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-333333333333"))
        let targetHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-managed-token-\(UUID().uuidString)", isDirectory: true)
        let siblingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-managed-token-sibling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: targetHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingHome, withIntermediateDirectories: true)
        let targetAccount = ManagedCodexAccount(
            id: targetID,
            email: "managed-token@example.com",
            providerAccountID: "acct-managed-token",
            workspaceLabel: "Managed Team",
            workspaceAccountID: "acct-managed-token",
            authFingerprint: "old-managed-token",
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let updatedTarget = ManagedCodexAccount(
            id: targetID,
            email: "managed-token@example.com",
            providerAccountID: "acct-managed-token",
            workspaceLabel: "Managed Team",
            workspaceAccountID: "acct-managed-token",
            authFingerprint: "new-managed-token",
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 3,
            lastAuthenticatedAt: 3)
        let siblingAccount = ManagedCodexAccount(
            id: siblingID,
            email: "managed-token-sibling@example.com",
            providerAccountID: "acct-managed-token-sibling",
            workspaceLabel: "Sibling Team",
            workspaceAccountID: "acct-managed-token-sibling",
            authFingerprint: "sibling-managed-token",
            managedHomePath: siblingHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [targetAccount, siblingAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: targetHome)
            try? FileManager.default.removeItem(at: siblingHome)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: targetID)

        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [])
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        let blocker = BlockingCodexFetchStrategy()
        let targetHomePath = targetHome.path
        let now = Date()
        self.installContextualCodexProvider(on: store) { context in
            if context.env["CODEX_HOME"] == targetHomePath {
                return try await blocker.awaitResult()
            }
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 9,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "managed-token-sibling@example.com",
                    accountOrganization: nil,
                    loginMethod: "Sibling Team"))
        }

        let refreshTask = Task { await store.refreshCodexVisibleAccountsForMenu() }
        await blocker.waitUntilStarted()
        try FileManagedCodexAccountStore(fileURL: storeURL).storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [updatedTarget, siblingAccount]))
        await blocker.resume(with: .failure(TestRefreshError(message: "old managed token failure")))
        await refreshTask.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.errors[.codex] == nil)
        #expect(!store.codexAccountSnapshots.contains {
            $0.account.workspaceAccountID == "acct-managed-token"
        })
        #expect(!snapshotStore.storedSnapshots.contains {
            $0.account.workspaceAccountID == "acct-managed-token"
        })
    }

    @Test
    func `stacked visible refresh discards selected failure after managed auth file rotates`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-selected-managed-auth-file-failure")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let targetID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-121212121212"))
        let siblingID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-131313131313"))
        let targetHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-managed-auth-file-\(UUID().uuidString)", isDirectory: true)
        let siblingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-managed-auth-file-sibling-\(UUID().uuidString)", isDirectory: true)
        try Self.writeCodexAuthFile(
            homeURL: targetHome,
            email: "managed-file-token@example.com",
            plan: "Pro",
            accountId: "acct-managed-file-token")
        let oldFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: targetHome.path))
        let targetAccount = ManagedCodexAccount(
            id: targetID,
            email: "managed-file-token@example.com",
            providerAccountID: "acct-managed-file-token",
            workspaceLabel: "Managed Team",
            workspaceAccountID: "acct-managed-file-token",
            authFingerprint: oldFingerprint,
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let siblingAccount = ManagedCodexAccount(
            id: siblingID,
            email: "managed-file-token-sibling@example.com",
            providerAccountID: "acct-managed-file-token-sibling",
            workspaceLabel: "Sibling Team",
            workspaceAccountID: "acct-managed-file-token-sibling",
            authFingerprint: "sibling-managed-file-token",
            managedHomePath: siblingHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [targetAccount, siblingAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: targetHome)
            try? FileManager.default.removeItem(at: siblingHome)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: targetID)

        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [])
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        let blocker = BlockingCodexFetchStrategy()
        let targetHomePath = targetHome.path
        let now = Date()
        self.installContextualCodexProvider(on: store) { context in
            if context.env["CODEX_HOME"] == targetHomePath {
                return try await blocker.awaitResult()
            }
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 9,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "managed-file-token-sibling@example.com",
                    accountOrganization: nil,
                    loginMethod: "Sibling Team"))
        }

        let refreshTask = Task { await store.refreshCodexVisibleAccountsForMenu() }
        await blocker.waitUntilStarted()
        try Self.writeCodexAuthFile(
            homeURL: targetHome,
            email: "managed-file-token@example.com",
            plan: "Team",
            accountId: "acct-managed-file-token")
        let newFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: targetHome.path))
        #expect(newFingerprint != oldFingerprint)
        await blocker.resume(with: .failure(TestRefreshError(message: "old managed auth file failure")))
        await refreshTask.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.errors[.codex] == nil)
        #expect(!store.codexAccountSnapshots.contains {
            $0.account.workspaceAccountID == "acct-managed-file-token"
        })
        #expect(!snapshotStore.storedSnapshots.contains {
            $0.account.workspaceAccountID == "acct-managed-file-token"
        })
    }

    @Test
    func `stacked visible refresh keeps selected failure when managed auth file rotated before start`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-selected-managed-auth-file-current-failure")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let targetID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-161616161616"))
        let siblingID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-171717171717"))
        let targetHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-managed-current-failure-\(UUID().uuidString)", isDirectory: true)
        let siblingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-managed-current-sibling-\(UUID().uuidString)", isDirectory: true)
        try Self.writeCodexAuthFile(
            homeURL: targetHome,
            email: "managed-current-failure@example.com",
            plan: "Pro",
            accountId: "acct-managed-current-failure")
        let oldFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: targetHome.path))
        let targetAccount = ManagedCodexAccount(
            id: targetID,
            email: "managed-current-failure@example.com",
            providerAccountID: "acct-managed-current-failure",
            workspaceLabel: "Managed Team",
            workspaceAccountID: "acct-managed-current-failure",
            authFingerprint: oldFingerprint,
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let siblingAccount = ManagedCodexAccount(
            id: siblingID,
            email: "managed-current-sibling@example.com",
            providerAccountID: "acct-managed-current-sibling",
            workspaceLabel: "Sibling Team",
            workspaceAccountID: "acct-managed-current-sibling",
            authFingerprint: "sibling-managed-current",
            managedHomePath: siblingHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [targetAccount, siblingAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: targetHome)
            try? FileManager.default.removeItem(at: siblingHome)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: targetID)

        try Self.writeCodexAuthFile(
            homeURL: targetHome,
            email: "managed-current-failure@example.com",
            plan: "Team",
            accountId: "acct-managed-current-failure")
        let newFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: targetHome.path))
        #expect(newFingerprint != oldFingerprint)

        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [])
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        let targetHomePath = targetHome.path
        let now = Date()
        self.installContextualCodexProvider(on: store) { context in
            if context.env["CODEX_HOME"] == targetHomePath {
                throw TestRefreshError(message: "current managed auth file failure")
            }
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 9,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "managed-current-sibling@example.com",
                    accountOrganization: nil,
                    loginMethod: "Sibling Team"))
        }

        await store.refreshCodexVisibleAccountsForMenu()

        #expect(store.errors[.codex] == "current managed auth file failure")
        let targetSnapshot = try #require(store.codexAccountSnapshots.first {
            $0.account.workspaceAccountID == "acct-managed-current-failure"
        })
        #expect(targetSnapshot.error == "current managed auth file failure")
        #expect(targetSnapshot.account.authFingerprint == newFingerprint)
        let persistedTargetSnapshot = try #require(snapshotStore.storedSnapshots.first {
            $0.account.workspaceAccountID == "acct-managed-current-failure"
        })
        #expect(persistedTargetSnapshot.error == "current managed auth file failure")
        #expect(persistedTargetSnapshot.account.authFingerprint == newFingerprint)
    }

    @Test
    func `stacked visible refresh discards selected success after managed auth file switches accounts`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-selected-managed-auth-file-success")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let targetID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-141414141414"))
        let siblingID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-151515151515"))
        let targetHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-managed-auth-success-\(UUID().uuidString)", isDirectory: true)
        let siblingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "codex-visible-managed-auth-success-sibling-\(UUID().uuidString)",
                isDirectory: true)
        try Self.writeCodexAuthFile(
            homeURL: targetHome,
            email: "managed-old-success@example.com",
            plan: "Pro",
            accountId: "acct-managed-old-success")
        let oldFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: targetHome.path))
        let targetAccount = ManagedCodexAccount(
            id: targetID,
            email: "managed-old-success@example.com",
            providerAccountID: "acct-managed-old-success",
            workspaceLabel: "Managed Team",
            workspaceAccountID: "acct-managed-old-success",
            authFingerprint: oldFingerprint,
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let siblingAccount = ManagedCodexAccount(
            id: siblingID,
            email: "managed-success-sibling@example.com",
            providerAccountID: "acct-managed-success-sibling",
            workspaceLabel: "Sibling Team",
            workspaceAccountID: "acct-managed-success-sibling",
            authFingerprint: "sibling-managed-success",
            managedHomePath: siblingHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [targetAccount, siblingAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: targetHome)
            try? FileManager.default.removeItem(at: siblingHome)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: targetID)

        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [])
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        let blocker = BlockingCodexFetchStrategy()
        let targetHomePath = targetHome.path
        let now = Date()
        self.installContextualCodexProvider(on: store) { context in
            if context.env["CODEX_HOME"] == targetHomePath {
                return try await blocker.awaitResult()
            }
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 9,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "managed-success-sibling@example.com",
                    accountOrganization: nil,
                    loginMethod: "Sibling Team"))
        }

        let refreshTask = Task { await store.refreshCodexVisibleAccountsForMenu() }
        await blocker.waitUntilStarted()
        try Self.writeCodexAuthFile(
            homeURL: targetHome,
            email: "managed-new-success@example.com",
            plan: "Pro",
            accountId: "acct-managed-new-success")
        let newFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: targetHome.path))
        #expect(newFingerprint != oldFingerprint)
        await blocker.resume(with: .success(UsageSnapshot(
            primary: RateWindow(
                usedPercent: 64,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "managed-old-success@example.com",
                accountOrganization: nil,
                loginMethod: "Managed Team"))))
        await refreshTask.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.errors[.codex] == nil)
        #expect(!store.codexAccountSnapshots.contains {
            $0.account.workspaceAccountID == "acct-managed-old-success"
        })
        #expect(!snapshotStore.storedSnapshots.contains {
            $0.account.workspaceAccountID == "acct-managed-old-success"
        })
    }

    @Test
    func `stacked visible refresh keeps migrated managed account after token rotation`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-migrated-managed-token-rotation")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let targetID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-171717171717"))
        let siblingID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-181818181818"))
        let targetHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-migrated-managed-\(UUID().uuidString)", isDirectory: true)
        let siblingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "codex-visible-migrated-managed-sibling-\(UUID().uuidString)",
                isDirectory: true)
        try Self.writeCodexAuthFile(
            homeURL: targetHome,
            email: "migrated-managed@example.com",
            plan: "Pro",
            accountId: "acct-migrated-managed")
        try Self.writeCodexAuthFile(
            homeURL: siblingHome,
            email: "migrated-sibling@example.com",
            plan: "Pro",
            accountId: "acct-migrated-sibling")
        let oldFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: targetHome.path))
        let siblingFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: siblingHome.path))
        let targetAccount = ManagedCodexAccount(
            id: targetID,
            email: "migrated-managed@example.com",
            providerAccountID: "acct-migrated-managed",
            workspaceLabel: "Managed Team",
            authFingerprint: oldFingerprint,
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let siblingAccount = ManagedCodexAccount(
            id: siblingID,
            email: "migrated-sibling@example.com",
            providerAccountID: "acct-migrated-sibling",
            workspaceLabel: "Sibling Team",
            authFingerprint: siblingFingerprint,
            managedHomePath: siblingHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [targetAccount, siblingAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: targetHome)
            try? FileManager.default.removeItem(at: siblingHome)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: targetID)

        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [])
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        let blocker = BlockingCodexFetchStrategy()
        let targetHomePath = targetHome.path
        let now = Date()
        self.installContextualCodexProvider(on: store) { context in
            if context.env["CODEX_HOME"] == targetHomePath {
                return try await blocker.awaitResult()
            }
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 9,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "migrated-sibling@example.com",
                    accountOrganization: nil,
                    loginMethod: "Sibling Team"))
        }

        let refreshTask = Task { await store.refreshCodexVisibleAccountsForMenu() }
        await blocker.waitUntilStarted()
        try Self.writeCodexAuthFile(
            homeURL: targetHome,
            email: "migrated-managed@example.com",
            plan: "Team",
            accountId: "acct-migrated-managed")
        let newFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: targetHome.path))
        #expect(newFingerprint != oldFingerprint)
        await blocker.resume(with: .success(UsageSnapshot(
            primary: RateWindow(
                usedPercent: 64,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "migrated-managed@example.com",
                accountOrganization: nil,
                loginMethod: "Managed Team"))))
        await refreshTask.value

        let selectedSnapshot = try #require(store.snapshots[.codex])
        #expect(selectedSnapshot.primary?.usedPercent == 64)
        let targetRow = try #require(store.codexAccountSnapshots.first {
            $0.account.workspaceAccountID == "acct-migrated-managed"
        })
        #expect(targetRow.account.authFingerprint == newFingerprint)
        #expect(targetRow.snapshot?.primary?.usedPercent == 64)
        let persistedTarget = try #require(snapshotStore.storedSnapshots.first {
            $0.account.workspaceAccountID == "acct-migrated-managed"
        })
        #expect(persistedTarget.account.authFingerprint == newFingerprint)
        #expect(persistedTarget.snapshot?.primary?.usedPercent == 64)
    }

    @Test
    func `stacked visible refresh discards selected success after managed auth file email changes`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-selected-managed-auth-email-success")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let targetID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-191919191919"))
        let siblingID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-202020202020"))
        let targetHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-managed-auth-email-\(UUID().uuidString)", isDirectory: true)
        let siblingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "codex-visible-managed-auth-email-sibling-\(UUID().uuidString)",
                isDirectory: true)
        try Self.writeCodexAuthFile(
            homeURL: targetHome,
            email: "managed-old-email@example.com",
            plan: "Pro",
            accountId: "acct-managed-email-same")
        try Self.writeCodexAuthFile(
            homeURL: siblingHome,
            email: "managed-email-sibling@example.com",
            plan: "Pro",
            accountId: "acct-managed-email-sibling")
        let oldFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: targetHome.path))
        let siblingFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: siblingHome.path))
        let targetAccount = ManagedCodexAccount(
            id: targetID,
            email: "managed-old-email@example.com",
            providerAccountID: "acct-managed-email-same",
            workspaceLabel: "Managed Team",
            workspaceAccountID: "acct-managed-email-same",
            authFingerprint: oldFingerprint,
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let siblingAccount = ManagedCodexAccount(
            id: siblingID,
            email: "managed-email-sibling@example.com",
            providerAccountID: "acct-managed-email-sibling",
            workspaceLabel: "Sibling Team",
            workspaceAccountID: "acct-managed-email-sibling",
            authFingerprint: siblingFingerprint,
            managedHomePath: siblingHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [targetAccount, siblingAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: targetHome)
            try? FileManager.default.removeItem(at: siblingHome)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: targetID)

        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [])
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        let blocker = BlockingCodexFetchStrategy()
        let targetHomePath = targetHome.path
        let now = Date()
        self.installContextualCodexProvider(on: store) { context in
            if context.env["CODEX_HOME"] == targetHomePath {
                return try await blocker.awaitResult()
            }
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 9,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "managed-email-sibling@example.com",
                    accountOrganization: nil,
                    loginMethod: "Sibling Team"))
        }

        let refreshTask = Task { await store.refreshCodexVisibleAccountsForMenu() }
        await blocker.waitUntilStarted()
        try Self.writeCodexAuthFile(
            homeURL: targetHome,
            email: "managed-new-email@example.com",
            plan: "Pro",
            accountId: "acct-managed-email-same")
        let newFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: targetHome.path))
        #expect(newFingerprint != oldFingerprint)
        await blocker.resume(with: .success(UsageSnapshot(
            primary: RateWindow(
                usedPercent: 64,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "managed-old-email@example.com",
                accountOrganization: nil,
                loginMethod: "Managed Team"))))
        await refreshTask.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.errors[.codex] == nil)
        #expect(!store.codexAccountSnapshots.contains {
            $0.account.workspaceAccountID == "acct-managed-email-same"
        })
        #expect(!snapshotStore.storedSnapshots.contains {
            $0.account.workspaceAccountID == "acct-managed-email-same"
        })
    }

    @Test
    func `managed failure guard reads current auth file fingerprint`() throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-managed-auth-file-fingerprint")
        settings.refreshFrequency = .manual
        let accountID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-555555555555"))
        let managedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-managed-auth-file-\(UUID().uuidString)", isDirectory: true)
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "managed-auth@example.com",
            plan: "Pro",
            accountId: "acct-managed-auth")
        let oldFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: managedHome.path))
        let managedAccount = ManagedCodexAccount(
            id: accountID,
            email: "managed-auth@example.com",
            providerAccountID: "acct-managed-auth",
            workspaceLabel: "Managed Auth",
            workspaceAccountID: "acct-managed-auth",
            authFingerprint: oldFingerprint,
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: managedHome)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: accountID)

        let store = self.makeUsageStore(settings: settings)
        let expectedGuard = store.freshCodexAccountScopedRefreshGuard()
        #expect(expectedGuard.authFingerprint == oldFingerprint)

        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "managed-auth@example.com",
            plan: "Team",
            accountId: "acct-managed-auth")
        let newFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: managedHome.path))
        #expect(newFingerprint != oldFingerprint)

        #expect(store.freshCodexAccountScopedRefreshGuard().authFingerprint == newFingerprint)
        #expect(!store.shouldApplyCodexScopedFailure(expectedGuard: expectedGuard))
        #expect(!store.shouldApplyCodexScopedNonUsageFailure(expectedGuard: expectedGuard))

        try FileManager.default.removeItem(at: managedHome)
        #expect(store.freshCodexAccountScopedRefreshGuard().authFingerprint == nil)
        let staleUsage = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 41,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "managed-auth@example.com",
                accountOrganization: nil,
                loginMethod: "Managed Auth"))
        #expect(!store.shouldApplyCodexUsageResult(expectedGuard: expectedGuard, usage: staleUsage))
        #expect(!store.shouldApplyCodexScopedFailure(expectedGuard: expectedGuard))
        #expect(!store.shouldApplyCodexScopedNonUsageFailure(expectedGuard: expectedGuard))
    }

    @Test
    func `stale auth fingerprint cache at refresh start keeps current codex usage success`() async {
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-stale-start-cache-current-auth")
        defer {
            SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = nil
            settings._test_liveSystemCodexAccount = nil
        }
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "old-email-only-auth",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "alpha@example.com"))
        let staleReconciliationSnapshot = settings.codexAccountReconciliationSnapshot
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "new-email-only-auth",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "alpha@example.com"))
        settings.cachedCodexAccountReconciliationSnapshot = CachedCodexAccountReconciliationSnapshot(
            activeSource: .liveSystem,
            loadedAt: Date(),
            snapshot: staleReconciliationSnapshot)

        let store = self.makeUsageStore(settings: settings)
        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        await blocker.waitUntilStarted()
        await blocker.resume(with: .success(self.codexSnapshot(email: "alpha@example.com", usedPercent: 33)))
        await refreshTask.value

        #expect(store.snapshots[.codex]?.primary?.usedPercent == 33)
        #expect(store.lastCodexAccountScopedRefreshGuard?.authFingerprint == "new-email-only-auth")
        #expect(store.errors[.codex] == nil)
    }

    @Test
    func `same provider account live email change discards stale codex usage success`() async {
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-provider-email-change")
        defer {
            SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = nil
            settings._test_liveSystemCodexAccount = nil
        }
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "old@example.com",
            authFingerprint: "old-provider-auth",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-shared"))
        let staleReconciliationSnapshot = settings.codexAccountReconciliationSnapshot

        let store = self.makeUsageStore(settings: settings)
        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        await blocker.waitUntilStarted()
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "new@example.com",
            authFingerprint: "new-provider-auth",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-shared"))
        settings.cachedCodexAccountReconciliationSnapshot = CachedCodexAccountReconciliationSnapshot(
            activeSource: .liveSystem,
            loadedAt: Date(),
            snapshot: staleReconciliationSnapshot)
        await blocker.resume(with: .success(self.codexSnapshot(email: "old@example.com", usedPercent: 25)))
        await refreshTask.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.errors[.codex] == nil)
    }

    @Test
    func `same provider account managed email change discards stale codex usage success`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-managed-provider-email-change")
        settings.refreshFrequency = .manual

        let accountID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-161616161616"))
        let managedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-managed-provider-email-\(UUID().uuidString)", isDirectory: true)
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "old-managed@example.com",
            plan: "Pro",
            accountId: "acct-managed-shared")
        let oldFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: managedHome.path))
        let managedAccount = ManagedCodexAccount(
            id: accountID,
            email: "old-managed@example.com",
            providerAccountID: "acct-managed-shared",
            workspaceLabel: "Managed Team",
            workspaceAccountID: "acct-managed-shared",
            authFingerprint: oldFingerprint,
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: managedHome)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: accountID)

        let store = self.makeUsageStore(settings: settings)
        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        await blocker.waitUntilStarted()
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "new-managed@example.com",
            plan: "Pro",
            accountId: "acct-managed-shared")
        let newFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: managedHome.path))
        #expect(newFingerprint != oldFingerprint)
        await blocker.resume(with: .success(self.codexSnapshot(email: "old-managed@example.com", usedPercent: 25)))
        await refreshTask.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.errors[.codex] == nil)
    }

    @Test
    func `managed codex usage success without email applies when auth guard matches`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-managed-usage-without-email")
        settings.refreshFrequency = .manual

        let accountID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-171717171717"))
        let managedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-managed-usage-without-email-\(UUID().uuidString)", isDirectory: true)
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "email-less-managed@example.com",
            plan: "Pro",
            accountId: "acct-managed-email-less")
        let authFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: managedHome.path))
        let managedAccount = ManagedCodexAccount(
            id: accountID,
            email: "email-less-managed@example.com",
            providerAccountID: "acct-managed-email-less",
            workspaceLabel: "Managed Team",
            workspaceAccountID: "acct-managed-email-less",
            authFingerprint: authFingerprint,
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: managedHome)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: accountID)

        let store = self.makeUsageStore(settings: settings)
        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        await blocker.waitUntilStarted()
        await blocker.resume(with: .success(UsageSnapshot(
            primary: RateWindow(
                usedPercent: 25,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date())))
        await refreshTask.value

        #expect(store.snapshots[.codex]?.primary?.usedPercent == 25)
        #expect(store.errors[.codex] == nil)
    }

    @Test
    func `same provider account managed email change discards stale codex usage success without email`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-managed-provider-email-change-without-email")
        settings.refreshFrequency = .manual

        let accountID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-181818181818"))
        let managedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "codex-managed-provider-email-without-email-\(UUID().uuidString)",
                isDirectory: true)
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "old-managed-empty@example.com",
            plan: "Pro",
            accountId: "acct-managed-shared-empty")
        let oldFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: managedHome.path))
        let managedAccount = ManagedCodexAccount(
            id: accountID,
            email: "old-managed-empty@example.com",
            providerAccountID: "acct-managed-shared-empty",
            workspaceLabel: "Managed Team",
            workspaceAccountID: "acct-managed-shared-empty",
            authFingerprint: oldFingerprint,
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: managedHome)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: accountID)

        let store = self.makeUsageStore(settings: settings)
        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        await blocker.waitUntilStarted()
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "new-managed-empty@example.com",
            plan: "Pro",
            accountId: "acct-managed-shared-empty")
        let newFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: managedHome.path))
        #expect(newFingerprint != oldFingerprint)
        await blocker.resume(with: .success(UsageSnapshot(
            primary: RateWindow(
                usedPercent: 25,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date())))
        await refreshTask.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.errors[.codex] == nil)
    }

    @Test
    func `same email email-only auth fingerprint switch discards stale codex usage success`() async {
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        let settings = self.makeSettingsStore(
            suite: "CodexAccountScopedRefreshTests-email-only-fingerprint-switch")
        defer {
            SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = nil
            settings._test_liveSystemCodexAccount = nil
        }
        settings.refreshFrequency = .manual
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "old-email-only-auth",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "alpha@example.com"))
        let staleReconciliationSnapshot = settings.codexAccountReconciliationSnapshot

        let store = self.makeUsageStore(settings: settings)
        let blocker = BlockingCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)

        let refreshTask = Task { await store.refreshProvider(.codex, allowDisabled: true) }
        await blocker.waitUntilStarted()
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "alpha@example.com",
            authFingerprint: "new-email-only-auth",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "alpha@example.com"))
        settings.cachedCodexAccountReconciliationSnapshot = CachedCodexAccountReconciliationSnapshot(
            activeSource: .liveSystem,
            loadedAt: Date(),
            snapshot: staleReconciliationSnapshot)
        await blocker.resume(with: .success(self.codexSnapshot(email: "alpha@example.com", usedPercent: 25)))
        await refreshTask.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.errors[.codex] == nil)
    }
}
