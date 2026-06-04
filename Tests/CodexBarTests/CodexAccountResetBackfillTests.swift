import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension CodexAccountScopedRefreshTests {
    @Test
    func `visible account refresh backfills known reset time before storing snapshots`() async throws {
        let settings = self.makeSettingsStore(suite: "CodexAccountResetBackfillTests-backfill")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "live@example.com")
        settings.codexActiveSource = .liveSystem

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-222222222222"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
        }
        settings._test_managedCodexAccountStoreURL = storeURL

        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [])
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        let knownReset = Date().addingTimeInterval(3600)
        store.lastKnownResetSnapshots[.codex] = self.codexSnapshot(
            email: "live@example.com",
            usedPercent: 5,
            resetsAt: knownReset)
        self.installImmediateCodexProvider(
            on: store,
            snapshot: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 6,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: "Resets 4:06 PM"),
                secondary: nil,
                updatedAt: Date(),
                identity: nil))

        await store.refreshCodexVisibleAccountsForMenu()

        let liveSnapshot = try #require(snapshotStore.storedSnapshots.first { $0.account.email == "live@example.com" })
        let managedSnapshot = try #require(snapshotStore.storedSnapshots
            .first { $0.account.email == "managed@example.com" })
        #expect(liveSnapshot.snapshot?.primary?.resetsAt == knownReset)
        #expect(store.codexAccountSnapshots.first { $0.account.email == "live@example.com" }?.snapshot?.primary?
            .resetsAt == knownReset)
        #expect(managedSnapshot.snapshot?.primary?.resetsAt == nil)
    }

    @Test
    func `visible account refresh does not backfill active cache from different email`() async throws {
        let settings = self.makeSettingsStore(suite: "CodexAccountResetBackfillTests-different-email-cache")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "new@example.com")
        settings.codexActiveSource = .liveSystem

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-111111111111"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
        }
        settings._test_managedCodexAccountStoreURL = storeURL

        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [])
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        store.lastKnownResetSnapshots[.codex] = self.codexSnapshot(
            email: "old@example.com",
            usedPercent: 5,
            resetsAt: Date().addingTimeInterval(3600))
        self.installImmediateCodexProvider(
            on: store,
            snapshot: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 6,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: Date(),
                identity: nil))

        await store.refreshCodexVisibleAccountsForMenu()

        let liveSnapshot = try #require(snapshotStore.storedSnapshots.first { $0.account.email == "new@example.com" })
        #expect(liveSnapshot.snapshot?.primary?.resetsAt == nil)
        #expect(store.snapshots[.codex]?.primary?.resetsAt == nil)
    }

    @Test
    func `visible account refresh does not backfill same email sibling account from active cache`() async throws {
        let settings = self.makeSettingsStore(suite: "CodexAccountResetBackfillTests-same-email")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "shared@example.com",
            identity: .providerAccount(id: "acct-live"))
        settings.codexActiveSource = .liveSystem

        let managedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedHome) }
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "shared@example.com",
            plan: "pro",
            accountId: "acct-managed")

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-333333333333"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "shared@example.com",
            workspaceLabel: "Managed Workspace",
            workspaceAccountID: "acct-managed",
            authFingerprint: "managed-auth",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let otherAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-999999999999"))
        let otherAccount = ManagedCodexAccount(
            id: otherAccountID,
            email: "other@example.com",
            managedHomePath: "/tmp/other-managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount, otherAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
        }
        settings._test_managedCodexAccountStoreURL = storeURL

        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [])
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        let knownReset = Date().addingTimeInterval(3600)
        store.lastKnownResetSnapshots[.codex] = self.codexSnapshot(
            email: "shared@example.com",
            usedPercent: 5,
            resetsAt: knownReset)
        self.installImmediateCodexProvider(
            on: store,
            snapshot: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 6,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: "Resets 4:06 PM"),
                secondary: nil,
                updatedAt: Date(),
                identity: nil))

        await store.refreshCodexVisibleAccountsForMenu()

        let liveSnapshot = try #require(snapshotStore.storedSnapshots.first { $0.account.isLive })
        let managedSnapshot = try #require(snapshotStore.storedSnapshots.first {
            !$0.account.isLive && $0.account.email == "shared@example.com"
        })
        #expect(liveSnapshot.account.email == "shared@example.com")
        #expect(managedSnapshot.account.email == "shared@example.com")
        #expect(liveSnapshot.snapshot?.primary?.resetsAt == nil)
        #expect(managedSnapshot.snapshot?.primary?.resetsAt == nil)
        #expect(store.snapshots[.codex]?.primary?.resetsAt == nil)
    }

    @Test
    func `visible account refresh does not backfill newly active same email account from previous active cache`()
        async throws
    {
        let settings = self.makeSettingsStore(suite: "CodexAccountResetBackfillTests-same-email-active-switch")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "shared@example.com",
            identity: .providerAccount(id: "acct-live"))

        let managedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedHome) }
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "shared@example.com",
            plan: "pro",
            accountId: "acct-managed")

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-555555555555"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "shared@example.com",
            workspaceLabel: "Managed Workspace",
            workspaceAccountID: "acct-managed",
            authFingerprint: "managed-auth",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let otherAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-777777777777"))
        let otherAccount = ManagedCodexAccount(
            id: otherAccountID,
            email: "other@example.com",
            managedHomePath: "/tmp/other-managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount, otherAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: managedAccountID)

        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [])
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        store.lastKnownResetSnapshots[.codex] = self.codexSnapshot(
            email: "shared@example.com",
            usedPercent: 5,
            resetsAt: Date().addingTimeInterval(3600))
        self.installImmediateCodexProvider(
            on: store,
            snapshot: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 6,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: "Resets 4:06 PM"),
                secondary: nil,
                updatedAt: Date(),
                identity: nil))

        await store.refreshCodexVisibleAccountsForMenu()

        let activeSnapshot = try #require(snapshotStore.storedSnapshots.first { $0.account.isActive })
        #expect(activeSnapshot.account.email == "shared@example.com")
        #expect(activeSnapshot.snapshot?.primary?.resetsAt == nil)
        #expect(store.snapshots[.codex]?.primary?.resetsAt == nil)
    }

    @Test
    func `single account refresh clears reset cache after same email source switch`() async throws {
        let settings = self.makeSettingsStore(suite: "CodexAccountResetBackfillTests-single-source-switch")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .segmented
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "shared@example.com",
            identity: .providerAccount(id: "acct-live"))
        settings.codexActiveSource = .liveSystem

        let managedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedHome) }
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "shared@example.com",
            plan: "pro",
            accountId: "acct-managed")

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-555555555556"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "shared@example.com",
            workspaceLabel: "Managed Workspace",
            workspaceAccountID: "acct-managed",
            authFingerprint: "managed-auth",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        defer {
            settings._test_activeManagedCodexAccount = nil
            settings._test_liveSystemCodexAccount = nil
        }
        settings._test_activeManagedCodexAccount = managedAccount

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store.lastCodexAccountScopedRefreshGuard = store.currentCodexAccountScopedRefreshGuard(
            preferCurrentSnapshot: false,
            allowLastKnownLiveFallback: false)
        store.lastKnownResetSnapshots[.codex] = self.codexSnapshot(
            email: "shared@example.com",
            usedPercent: 5,
            resetsAt: Date().addingTimeInterval(3600))
        settings.codexActiveSource = .managedAccount(id: managedAccountID)
        #expect(store.prepareCodexAccountScopedRefreshIfNeeded())
        self.installImmediateCodexProvider(
            on: store,
            snapshot: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 6,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "shared@example.com",
                    accountOrganization: nil,
                    loginMethod: "Pro")))

        await store.refreshProvider(.codex, allowDisabled: true)

        #expect(store.snapshots[.codex]?.primary?.resetsAt == nil)
        #expect(store.lastKnownResetSnapshots[.codex]?.primary?.resetsAt == nil)
    }

    @Test
    func `visible account refresh does not backfill collapsed same email id from prior sibling`() async throws {
        let settings = self.makeSettingsStore(suite: "CodexAccountResetBackfillTests-same-email-id-collapse")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let managedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedHome) }
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "shared@example.com",
            plan: "pro",
            accountId: "acct-managed")

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-888888888888"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "shared@example.com",
            workspaceLabel: "Managed Workspace",
            workspaceAccountID: "acct-managed",
            authFingerprint: "managed-auth",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let otherAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-666666666666"))
        let otherAccount = ManagedCodexAccount(
            id: otherAccountID,
            email: "other@example.com",
            managedHomePath: "/tmp/other-managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount, otherAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: managedAccountID)

        let liveSibling = CodexVisibleAccount(
            id: "live:acct-live",
            email: "shared@example.com",
            workspaceLabel: "Live Workspace",
            workspaceAccountID: "acct-live",
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: true,
            isLive: true,
            canReauthenticate: true,
            canRemove: false)
        let priorSnapshots = [
            CodexAccountUsageSnapshot(
                account: liveSibling,
                snapshot: self.codexSnapshot(
                    email: "shared@example.com",
                    usedPercent: 5,
                    resetsAt: Date().addingTimeInterval(3600)),
                error: nil,
                sourceLabel: "cached"),
        ]
        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: priorSnapshots)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        store.codexAccountSnapshots = priorSnapshots
        store.lastKnownResetSnapshots[.codex] = self.codexSnapshot(
            email: "shared@example.com",
            usedPercent: 5,
            resetsAt: Date().addingTimeInterval(3600))
        self.installImmediateCodexProvider(
            on: store,
            snapshot: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 6,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "shared@example.com",
                    accountOrganization: nil,
                    loginMethod: "Pro")))

        await store.refreshCodexVisibleAccountsForMenu()

        let activeSnapshot = try #require(snapshotStore.storedSnapshots.first { $0.account.isActive })
        #expect(activeSnapshot.account.id == "shared@example.com")
        #expect(activeSnapshot.account.selectionSource == .managedAccount(id: managedAccountID))
        #expect(activeSnapshot.snapshot?.primary?.resetsAt == nil)
        #expect(store.snapshots[.codex]?.primary?.resetsAt == nil)
    }

    @Test
    func `visible account refresh does not backfill reused email id from different source`() async throws {
        let settings = self.makeSettingsStore(suite: "CodexAccountResetBackfillTests-reused-email-id-source")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let managedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedHome) }
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "shared@example.com",
            plan: "pro",
            accountId: "acct-managed")

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-999999999997"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "shared@example.com",
            workspaceLabel: "Managed Workspace",
            workspaceAccountID: "acct-managed",
            authFingerprint: "managed-auth",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let otherAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-999999999996"))
        let otherAccount = ManagedCodexAccount(
            id: otherAccountID,
            email: "other@example.com",
            managedHomePath: "/tmp/other-managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount, otherAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: managedAccountID)

        let priorLiveSameID = CodexVisibleAccount(
            id: "shared@example.com",
            email: "shared@example.com",
            workspaceLabel: "Live Workspace",
            workspaceAccountID: nil,
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: true,
            isLive: true,
            canReauthenticate: true,
            canRemove: false)
        let priorSnapshots = [
            CodexAccountUsageSnapshot(
                account: priorLiveSameID,
                snapshot: self.codexSnapshot(
                    email: "shared@example.com",
                    usedPercent: 5,
                    resetsAt: Date().addingTimeInterval(3600)),
                error: nil,
                sourceLabel: "cached"),
        ]
        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: priorSnapshots)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        store.codexAccountSnapshots = priorSnapshots
        store.lastKnownResetSnapshots[.codex] = self.codexSnapshot(
            email: "shared@example.com",
            usedPercent: 5,
            resetsAt: Date().addingTimeInterval(3600))
        self.installImmediateCodexProvider(
            on: store,
            snapshot: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 6,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "shared@example.com",
                    accountOrganization: nil,
                    loginMethod: "Pro")))

        await store.refreshCodexVisibleAccountsForMenu()

        let activeSnapshot = try #require(snapshotStore.storedSnapshots.first { $0.account.isActive })
        #expect(activeSnapshot.account.id == "shared@example.com")
        #expect(activeSnapshot.account.selectionSource == .managedAccount(id: managedAccountID))
        #expect(activeSnapshot.snapshot?.primary?.resetsAt == nil)
        #expect(store.snapshots[.codex]?.primary?.resetsAt == nil)
    }

    @Test
    func `visible account refresh does not backfill changed live id from prior live account`() async throws {
        let settings = self.makeSettingsStore(suite: "CodexAccountResetBackfillTests-live-id-change")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "shared@example.com",
            identity: .providerAccount(id: "acct-new"))
        settings.codexActiveSource = .liveSystem

        let managedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedHome) }
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "shared@example.com",
            plan: "pro",
            accountId: "acct-managed")

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-999999999998"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "shared@example.com",
            workspaceLabel: "Managed Workspace",
            workspaceAccountID: "acct-managed",
            authFingerprint: "managed-auth",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
        }
        settings._test_managedCodexAccountStoreURL = storeURL

        let projection = settings.codexVisibleAccountProjection
        let currentLive = try #require(projection.visibleAccounts.first { $0.selectionSource == .liveSystem })
        #expect(currentLive.id == "live:provider:acct-new")
        let priorLive = CodexVisibleAccount(
            id: "live:provider:acct-old",
            email: "shared@example.com",
            workspaceLabel: "Old Live Workspace",
            workspaceAccountID: "acct-old",
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: true,
            isLive: true,
            canReauthenticate: true,
            canRemove: false)
        let priorSnapshots = [
            CodexAccountUsageSnapshot(
                account: priorLive,
                snapshot: self.codexSnapshot(
                    email: "shared@example.com",
                    usedPercent: 5,
                    resetsAt: Date().addingTimeInterval(3600)),
                error: nil,
                sourceLabel: "cached"),
        ]
        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: priorSnapshots)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        store.codexAccountSnapshots = priorSnapshots
        self.installImmediateCodexProvider(
            on: store,
            snapshot: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 6,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "shared@example.com",
                    accountOrganization: nil,
                    loginMethod: "Pro")))

        await store.refreshCodexVisibleAccountsForMenu()

        let liveSnapshot = try #require(snapshotStore.storedSnapshots.first { $0.account.id == currentLive.id })
        #expect(liveSnapshot.snapshot?.primary?.resetsAt == nil)
        #expect(store.snapshots[.codex]?.primary?.resetsAt == nil)
    }

    @Test
    func `visible account refresh does not backfill same id when stable live identity changes`() async throws {
        let settings = self.makeSettingsStore(suite: "CodexAccountResetBackfillTests-same-id-live-identity")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "shared@example.com",
            workspaceLabel: "New Live Workspace",
            workspaceAccountID: "acct-new",
            authFingerprint: "new-auth",
            codexHomePath: "/Users/test/.codex-new",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-new"))
        settings.codexActiveSource = .liveSystem

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-999999999997"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
        }
        settings._test_managedCodexAccountStoreURL = storeURL

        let projection = settings.codexVisibleAccountProjection
        let currentLive = try #require(projection.visibleAccounts.first { $0.selectionSource == .liveSystem })
        #expect(currentLive.id == "shared@example.com")
        #expect(currentLive.workspaceAccountID == "acct-new")
        let priorLiveSameID = CodexVisibleAccount(
            id: currentLive.id,
            email: "shared@example.com",
            workspaceLabel: "Old Live Workspace",
            workspaceAccountID: "acct-old",
            authFingerprint: "old-auth",
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: true,
            isLive: true,
            canReauthenticate: true,
            canRemove: false)
        let priorSnapshots = [
            CodexAccountUsageSnapshot(
                account: priorLiveSameID,
                snapshot: self.codexSnapshot(
                    email: "shared@example.com",
                    usedPercent: 5,
                    resetsAt: Date().addingTimeInterval(3600)),
                error: nil,
                sourceLabel: "cached"),
        ]
        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: priorSnapshots)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        store.codexAccountSnapshots = priorSnapshots
        self.installImmediateCodexProvider(
            on: store,
            snapshot: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 6,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "shared@example.com",
                    accountOrganization: nil,
                    loginMethod: "Pro")))

        await store.refreshCodexVisibleAccountsForMenu()

        let liveSnapshot = try #require(snapshotStore.storedSnapshots.first { $0.account.id == currentLive.id })
        #expect(liveSnapshot.account.workspaceAccountID == "acct-new")
        #expect(liveSnapshot.snapshot?.primary?.resetsAt == nil)
        #expect(store.snapshots[.codex]?.primary?.resetsAt == nil)
    }

    @Test
    func `visible account refresh repairs collapsed codex windows from matching cached account`() async throws {
        let settings = self.makeSettingsStore(suite: "CodexAccountResetBackfillTests-collapsed")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "live@example.com")
        settings.codexActiveSource = .liveSystem

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-444444444444"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
        }
        settings._test_managedCodexAccountStoreURL = storeURL

        let projection = settings.codexVisibleAccountProjection
        let liveAccount = try #require(projection.visibleAccounts.first { $0.email == "live@example.com" })
        let sessionReset = Date().addingTimeInterval(3600)
        let weeklyReset = Date().addingTimeInterval(7 * 24 * 3600)
        let cachedSnapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 1,
                windowMinutes: 300,
                resetsAt: sessionReset,
                resetDescription: "4:06 PM"),
            secondary: RateWindow(
                usedPercent: 7,
                windowMinutes: 10080,
                resetsAt: weeklyReset,
                resetDescription: "next week"),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "live@example.com",
                accountOrganization: nil,
                loginMethod: "Pro"))
        let priorSnapshots = [
            CodexAccountUsageSnapshot(
                account: liveAccount,
                snapshot: cachedSnapshot,
                error: nil,
                sourceLabel: "cached"),
        ]
        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: priorSnapshots)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        store.codexAccountSnapshots = priorSnapshots
        self.installImmediateCodexProvider(
            on: store,
            snapshot: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 1,
                    windowMinutes: 0,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "live@example.com",
                    accountOrganization: nil,
                    loginMethod: "Pro")))

        await store.refreshCodexVisibleAccountsForMenu()

        let liveSnapshot = try #require(snapshotStore.storedSnapshots.first { $0.account.id == liveAccount.id })
        #expect(liveSnapshot.snapshot?.primary?.usedPercent == 1)
        #expect(liveSnapshot.snapshot?.primary?.windowMinutes == 300)
        #expect(liveSnapshot.snapshot?.primary?.resetsAt == sessionReset)
        #expect(liveSnapshot.snapshot?.primary?.resetDescription == "4:06 PM")
        #expect(liveSnapshot.snapshot?.secondary?.usedPercent == 7)
        #expect(liveSnapshot.snapshot?.secondary?.windowMinutes == 10080)
        #expect(liveSnapshot.snapshot?.secondary?.resetsAt == weeklyReset)
        #expect(liveSnapshot.snapshot?.secondary?.resetDescription == "next week")
        #expect(store.snapshots[.codex]?.primary?.resetsAt == sessionReset)
        #expect(store.snapshots[.codex]?.secondary?.resetsAt == weeklyReset)

        if ProcessInfo.processInfo.environment["CODEXBAR_RESET_BACKFILL_PROOF"] == "1" {
            let formatter = ISO8601DateFormatter()
            print("""

            Codex visible-account reset backfill proof
            path=UsageStore.refreshCodexVisibleAccountsForMenu()
            account=[redacted-live-account]
            fresh.primary.usedPercent=1
            fresh.primary.windowMinutes=0
            fresh.primary.resetsAt=nil
            fresh.secondary=nil
            cached.primary.windowMinutes=300
            cached.primary.resetsAt=\(formatter.string(from: sessionReset))
            cached.secondary.windowMinutes=10080
            cached.secondary.resetsAt=\(formatter.string(from: weeklyReset))
            stored.primary.usedPercent=\(liveSnapshot.snapshot?.primary?.usedPercent ?? -1)
            stored.primary.windowMinutes=\(liveSnapshot.snapshot?.primary?.windowMinutes ?? -1)
            stored.primary.resetsAt=\(liveSnapshot.snapshot?.primary?.resetsAt
                .map { formatter.string(from: $0) } ?? "nil")
            stored.secondary.usedPercent=\(liveSnapshot.snapshot?.secondary?.usedPercent ?? -1)
            stored.secondary.windowMinutes=\(liveSnapshot.snapshot?.secondary?.windowMinutes ?? -1)
            stored.secondary.resetsAt=\(liveSnapshot.snapshot?.secondary?.resetsAt
                .map { formatter.string(from: $0) } ?? "nil")
            selected.primary.resetsAt=\(store.snapshots[.codex]?.primary?.resetsAt
                .map { formatter.string(from: $0) } ?? "nil")
            selected.secondary.resetsAt=\(store.snapshots[.codex]?.secondary?.resetsAt
                .map { formatter.string(from: $0) } ?? "nil")
            result=PASS cached reset/window metadata preserved when fresh visible-account response omitted it
            """)
        }
    }

    @Test
    func `visible account refresh does not promote undated cached secondary window`() async throws {
        let settings = self.makeSettingsStore(suite: "CodexAccountResetBackfillTests-undated-secondary")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "live@example.com")
        settings.codexActiveSource = .liveSystem

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-666666666666"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
        }
        settings._test_managedCodexAccountStoreURL = storeURL

        let projection = settings.codexVisibleAccountProjection
        let liveAccount = try #require(projection.visibleAccounts.first { $0.email == "live@example.com" })
        let cachedSnapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 1,
                windowMinutes: 300,
                resetsAt: Date().addingTimeInterval(3600),
                resetDescription: "4:06 PM"),
            secondary: RateWindow(
                usedPercent: 7,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: "next week"),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "live@example.com",
                accountOrganization: nil,
                loginMethod: "Pro"))
        let priorSnapshots = [
            CodexAccountUsageSnapshot(
                account: liveAccount,
                snapshot: cachedSnapshot,
                error: nil,
                sourceLabel: "cached"),
        ]
        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: priorSnapshots)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        store.codexAccountSnapshots = priorSnapshots
        self.installImmediateCodexProvider(
            on: store,
            snapshot: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 1,
                    windowMinutes: 0,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "live@example.com",
                    accountOrganization: nil,
                    loginMethod: "Pro")))

        await store.refreshCodexVisibleAccountsForMenu()

        let liveSnapshot = try #require(snapshotStore.storedSnapshots.first { $0.account.id == liveAccount.id })
        #expect(liveSnapshot.snapshot?.primary?.windowMinutes == 300)
        #expect(liveSnapshot.snapshot?.secondary == nil)
    }

    @Test
    func `visible account refresh does not backfill expired cached reset descriptions`() async throws {
        let settings = self.makeSettingsStore(suite: "CodexAccountResetBackfillTests-expired-reset-text")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "live@example.com")
        settings.codexActiveSource = .liveSystem

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-777777777777"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
        }
        settings._test_managedCodexAccountStoreURL = storeURL

        let projection = settings.codexVisibleAccountProjection
        let liveAccount = try #require(projection.visibleAccounts.first { $0.email == "live@example.com" })
        let cachedSnapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 1,
                windowMinutes: 300,
                resetsAt: Date().addingTimeInterval(-3600),
                resetDescription: "Resets in stale cached text"),
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "live@example.com",
                accountOrganization: nil,
                loginMethod: "Pro"))
        let priorSnapshots = [
            CodexAccountUsageSnapshot(
                account: liveAccount,
                snapshot: cachedSnapshot,
                error: nil,
                sourceLabel: "cached"),
        ]
        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: priorSnapshots)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        store.codexAccountSnapshots = priorSnapshots
        self.installImmediateCodexProvider(
            on: store,
            snapshot: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 1,
                    windowMinutes: 0,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "live@example.com",
                    accountOrganization: nil,
                    loginMethod: "Pro")))

        await store.refreshCodexVisibleAccountsForMenu()

        let liveSnapshot = try #require(snapshotStore.storedSnapshots.first { $0.account.id == liveAccount.id })
        #expect(liveSnapshot.snapshot?.primary?.windowMinutes == 300)
        #expect(liveSnapshot.snapshot?.primary?.resetsAt == nil)
        #expect(liveSnapshot.snapshot?.primary?.resetDescription == nil)
        #expect(store.snapshots[.codex]?.primary?.resetsAt == nil)
        #expect(store.snapshots[.codex]?.primary?.resetDescription == nil)
    }
}
