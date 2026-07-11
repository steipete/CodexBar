import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `provider only history never backfills account quota publication`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountVisibleHistoryBackfillTests")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let targetID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-222222222222"))
        let siblingID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-333333333333"))
        let targetHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-target-\(UUID().uuidString)", isDirectory: true)
        let siblingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-sibling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: targetHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingHome, withIntermediateDirectories: true)
        let targetAccount = ManagedCodexAccount(
            id: targetID,
            email: "target@example.com",
            providerAccountID: "acct-target",
            workspaceLabel: "Target Team",
            workspaceAccountID: "acct-target",
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let siblingAccount = ManagedCodexAccount(
            id: siblingID,
            email: "sibling@example.com",
            providerAccountID: "acct-sibling",
            workspaceLabel: "Sibling Team",
            workspaceAccountID: "acct-sibling",
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
        let now = Date()
        self.installContextualCodexProvider(on: store) { context in
            let isTarget = context.env["CODEX_HOME"] == targetHome.path
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: isTarget ? 1 : 22,
                    windowMinutes: 0,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now)
        }

        let targetHistoryKey = try #require(CodexHistoryOwnership.canonicalKey(for: .providerAccount(
            id: "acct-target")))
        let sessionReset = now.addingTimeInterval(4 * 60 * 60)
        let weeklyReset = now.addingTimeInterval(4 * 24 * 60 * 60)
        store.planUtilizationHistory[.codex] = PlanUtilizationHistoryBuckets(accounts: [
            targetHistoryKey: [
                planSeries(name: .session, windowMinutes: 300, entries: [
                    planEntry(at: now.addingTimeInterval(-60), usedPercent: 1, resetsAt: sessionReset),
                ]),
                planSeries(name: .weekly, windowMinutes: 10080, entries: [
                    planEntry(at: now.addingTimeInterval(-60), usedPercent: 13, resetsAt: weeklyReset),
                ]),
            ],
        ])

        await store.refreshCodexVisibleAccountsForMenu()

        let targetSnapshot = try #require(store.codexAccountSnapshots.first {
            $0.account.workspaceAccountID == "acct-target"
        }?.snapshot)
        #expect(targetSnapshot.primary?.usedPercent == 1)
        #expect(targetSnapshot.primary?.windowMinutes == 0)
        #expect(targetSnapshot.primary?.resetsAt == nil)
        #expect(targetSnapshot.secondary == nil)

        let siblingSnapshot = try #require(store.codexAccountSnapshots.first {
            $0.account.workspaceAccountID == "acct-sibling"
        }?.snapshot)
        #expect(siblingSnapshot.primary?.windowMinutes == 0)
        #expect(siblingSnapshot.primary?.resetsAt == nil)
        #expect(siblingSnapshot.secondary == nil)

        let persistedTarget = try #require(snapshotStore.storedSnapshots.first {
            $0.account.workspaceAccountID == "acct-target"
        }?.snapshot)
        #expect(persistedTarget.primary?.resetsAt == nil)
        #expect(persistedTarget.secondary == nil)
        #expect(store.snapshots[.codex]?.primary?.resetsAt == nil)
        #expect(store.snapshots[.codex]?.secondary == nil)
        #expect(store.planUtilizationHistory[.codex]?.accounts[targetHistoryKey]?.count == 2)
    }

    @Test
    func `materializes single visible codex account email history into provider account history`() throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountVisibleHistoryBackfillTests-single-account-materialize")
        let store = self.makeUsageStore(settings: settings)
        let visibleAccount = CodexVisibleAccount(
            id: "materialize@example.com",
            email: "materialize@example.com",
            workspaceLabel: "Target Team",
            workspaceAccountID: "acct-materialize",
            storedAccountID: nil,
            selectionSource: .managedAccount(id: UUID()),
            isActive: true,
            isLive: false,
            canReauthenticate: true,
            canRemove: true)
        let providerHistoryKey = try #require(CodexHistoryOwnership.canonicalKey(for: .providerAccount(
            id: "acct-materialize")))
        let emailHistoryKey = CodexHistoryOwnership.canonicalEmailHashKey(for: "materialize@example.com")
        let legacyEmailHistoryKey = UsageStore._codexLegacyPlanUtilizationEmailHashKeyForTesting(
            normalizedEmail: "materialize@example.com")
        let session = planSeries(name: .session, windowMinutes: 300, entries: [
            planEntry(at: Date(timeIntervalSince1970: 1_800_000_000), usedPercent: 1),
        ])
        let weekly = planSeries(name: .weekly, windowMinutes: 10080, entries: [
            planEntry(at: Date(timeIntervalSince1970: 1_800_086_400), usedPercent: 13),
        ])
        store.planUtilizationHistory[.codex] = PlanUtilizationHistoryBuckets(accounts: [
            emailHistoryKey: [session],
            legacyEmailHistoryKey: [weekly],
        ])

        let histories = store.codexPlanUtilizationHistories(forVisibleAccount: visibleAccount)

        #expect(histories == [session, weekly])
        #expect(store.planUtilizationHistory[.codex]?.accounts[providerHistoryKey] == [session, weekly])
        #expect(store.planUtilizationHistory[.codex]?.accounts[emailHistoryKey] == nil)
        #expect(store.planUtilizationHistory[.codex]?.accounts[legacyEmailHistoryKey] == nil)
    }

    @Test
    func `materializes provider account email history when sibling visible account uses another email`() throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountVisibleHistoryBackfillTests-different-email-materialize")
        settings.multiAccountMenuLayout = .stacked
        let targetID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-121212121212"))
        let siblingID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-343434343434"))
        let targetAccount = ManagedCodexAccount(
            id: targetID,
            email: "materialize-stack@example.com",
            providerAccountID: "acct-materialize-stack",
            workspaceLabel: "Target Team",
            workspaceAccountID: "acct-materialize-stack",
            managedHomePath: "/tmp/materialize-stack-target",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let siblingAccount = ManagedCodexAccount(
            id: siblingID,
            email: "other-stack@example.com",
            providerAccountID: "acct-materialize-other",
            workspaceLabel: "Other Team",
            workspaceAccountID: "acct-materialize-other",
            managedHomePath: "/tmp/materialize-stack-other",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [targetAccount, siblingAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: targetID)
        let store = self.makeUsageStore(settings: settings)
        let visibleAccount = try #require(settings.codexVisibleAccountProjection.visibleAccounts.first {
            $0.workspaceAccountID == "acct-materialize-stack"
        })
        let providerHistoryKey = try #require(CodexHistoryOwnership.canonicalKey(for: .providerAccount(
            id: "acct-materialize-stack")))
        let emailHistoryKey = CodexHistoryOwnership.canonicalEmailHashKey(for: "materialize-stack@example.com")
        let legacyEmailHistoryKey = UsageStore._codexLegacyPlanUtilizationEmailHashKeyForTesting(
            normalizedEmail: "materialize-stack@example.com")
        let session = planSeries(name: .session, windowMinutes: 300, entries: [
            planEntry(at: Date(timeIntervalSince1970: 1_800_000_000), usedPercent: 1),
        ])
        let weekly = planSeries(name: .weekly, windowMinutes: 10080, entries: [
            planEntry(at: Date(timeIntervalSince1970: 1_800_086_400), usedPercent: 13),
        ])
        store.planUtilizationHistory[.codex] = PlanUtilizationHistoryBuckets(accounts: [
            emailHistoryKey: [session],
            legacyEmailHistoryKey: [weekly],
        ])

        let histories = store.codexPlanUtilizationHistories(forVisibleAccount: visibleAccount)

        #expect(histories == [session, weekly])
        #expect(store.planUtilizationHistory[.codex]?.accounts[providerHistoryKey] == [session, weekly])
        #expect(store.planUtilizationHistory[.codex]?.accounts[emailHistoryKey] == nil)
        #expect(store.planUtilizationHistory[.codex]?.accounts[legacyEmailHistoryKey] == nil)
    }

    @Test
    func `selected codex refresh keeps ambiguous same email history out of provider account`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountVisibleHistoryBackfillTests-selected-ambiguous-history")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let targetID = try #require(UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-111111111111"))
        let siblingID = try #require(UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-222222222222"))
        let targetHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-selected-history-target-\(UUID().uuidString)", isDirectory: true)
        let siblingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-selected-history-sibling-\(UUID().uuidString)", isDirectory: true)
        try Self.writeCodexAuthFile(
            homeURL: targetHome,
            email: "selected-shared@example.com",
            plan: "pro",
            accountId: "acct-selected-target")
        try Self.writeCodexAuthFile(
            homeURL: siblingHome,
            email: "selected-shared@example.com",
            plan: "pro",
            accountId: "acct-selected-sibling")
        let targetAccount = ManagedCodexAccount(
            id: targetID,
            email: "selected-shared@example.com",
            providerAccountID: "acct-selected-target",
            workspaceLabel: "Target Team",
            workspaceAccountID: "acct-selected-target",
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let siblingAccount = ManagedCodexAccount(
            id: siblingID,
            email: "selected-shared@example.com",
            providerAccountID: "acct-selected-sibling",
            workspaceLabel: "Sibling Team",
            workspaceAccountID: "acct-selected-sibling",
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

        let store = self.makeUsageStore(settings: settings)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let providerHistoryKey = try #require(CodexHistoryOwnership.canonicalKey(for: .providerAccount(
            id: "acct-selected-target")))
        let emailHistoryKey = CodexHistoryOwnership.canonicalEmailHashKey(for: "selected-shared@example.com")
        let legacyEmailHistoryKey = UsageStore._codexLegacyPlanUtilizationEmailHashKeyForTesting(
            normalizedEmail: "selected-shared@example.com")
        let staleSession = planSeries(name: .session, windowMinutes: 300, entries: [
            planEntry(at: now.addingTimeInterval(-2 * 60 * 60), usedPercent: 12),
        ])
        let staleWeekly = planSeries(name: .weekly, windowMinutes: 10080, entries: [
            planEntry(at: now.addingTimeInterval(-2 * 60 * 60), usedPercent: 24),
        ])
        store.planUtilizationHistory[.codex] = PlanUtilizationHistoryBuckets(accounts: [
            emailHistoryKey: [staleSession],
            legacyEmailHistoryKey: [staleWeekly],
        ])
        let currentSnapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 4,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3 * 60 * 60),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 6,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60),
                resetDescription: nil),
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "selected-shared@example.com",
                accountOrganization: nil,
                loginMethod: "Target Team"))

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: currentSnapshot,
            now: now)

        let buckets = try #require(store.planUtilizationHistory[.codex])
        let providerHistory = try #require(buckets.accounts[providerHistoryKey])
        #expect(providerHistory.flatMap(\.entries).allSatisfy { $0.capturedAt == now })
        #expect(buckets.accounts[emailHistoryKey] == [staleSession])
        #expect(buckets.accounts[legacyEmailHistoryKey] == [staleWeekly])
    }

    @Test
    func `ignores active reset cache from another visible codex workspace`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountVisibleHistoryBackfillTests-stale-active-cache")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let targetID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-444444444444"))
        let siblingID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-555555555555"))
        let targetHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-cache-target-\(UUID().uuidString)", isDirectory: true)
        let siblingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-cache-sibling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: targetHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingHome, withIntermediateDirectories: true)
        let targetAccount = ManagedCodexAccount(
            id: targetID,
            email: "shared@example.com",
            providerAccountID: "acct-cache-target",
            workspaceLabel: "Target Team",
            workspaceAccountID: "acct-cache-target",
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let siblingAccount = ManagedCodexAccount(
            id: siblingID,
            email: "shared@example.com",
            providerAccountID: "acct-cache-sibling",
            workspaceLabel: "Sibling Team",
            workspaceAccountID: "acct-cache-sibling",
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
        let now = Date()
        let staleReset = now.addingTimeInterval(2 * 60 * 60)
        store.lastCodexAccountScopedRefreshGuard = CodexAccountScopedRefreshGuard(
            source: .managedAccount(id: siblingID),
            identity: .providerAccount(id: "acct-cache-sibling"),
            accountKey: "shared@example.com")
        store.lastKnownResetSnapshots[.codex] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 44,
                windowMinutes: 300,
                resetsAt: staleReset,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 55,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(2 * 24 * 60 * 60),
                resetDescription: nil),
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "shared@example.com",
                accountOrganization: nil,
                loginMethod: "Sibling Team"))
        self.installContextualCodexProvider(on: store) { context in
            let isTarget = context.env["CODEX_HOME"] == targetHome.path
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: isTarget ? 4 : 9,
                    windowMinutes: 0,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now.addingTimeInterval(1))
        }

        await store.refreshCodexVisibleAccountsForMenu()

        let targetSnapshot = try #require(store.codexAccountSnapshots.first {
            $0.account.workspaceAccountID == "acct-cache-target"
        }?.snapshot)
        #expect(targetSnapshot.primary?.usedPercent == 4)
        #expect(targetSnapshot.primary?.windowMinutes == 0)
        #expect(targetSnapshot.primary?.resetsAt == nil)
        #expect(targetSnapshot.secondary == nil)
        #expect(store.snapshots[.codex]?.primary?.resetsAt == nil)
        #expect(store.snapshots[.codex]?.secondary == nil)
        #expect(store.lastKnownResetSnapshots[.codex]?.primary?.resetsAt == nil)
        #expect(snapshotStore.storedSnapshots.first {
            $0.account.workspaceAccountID == "acct-cache-target"
        }?.snapshot?.primary?.resetsAt == nil)
    }

    @Test
    func `uses active reset cache when scoped guard matches codex workspace with plan label`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountVisibleHistoryBackfillTests-current-active-cache")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let targetID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-666666666666"))
        let siblingID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-777777777777"))
        let targetHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-current-target-\(UUID().uuidString)", isDirectory: true)
        let siblingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-current-sibling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: targetHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingHome, withIntermediateDirectories: true)
        let targetAccount = ManagedCodexAccount(
            id: targetID,
            email: "current@example.com",
            providerAccountID: "acct-current-target",
            workspaceLabel: "Target Team",
            workspaceAccountID: "acct-current-target",
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let siblingAccount = ManagedCodexAccount(
            id: siblingID,
            email: "current@example.com",
            providerAccountID: "acct-current-sibling",
            workspaceLabel: "Sibling Team",
            workspaceAccountID: "acct-current-sibling",
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

        let now = Date()
        let staleSessionReset = now.addingTimeInterval(3 * 60 * 60)
        let staleWeeklyReset = now.addingTimeInterval(3 * 24 * 60 * 60)
        let priorSnapshots = settings.codexVisibleAccountProjection.visibleAccounts.map { account in
            CodexAccountUsageSnapshot(
                account: account,
                snapshot: account.workspaceAccountID == "acct-current-target"
                    ? UsageSnapshot(
                        primary: RateWindow(
                            usedPercent: 2,
                            windowMinutes: 300,
                            resetsAt: staleSessionReset,
                            resetDescription: nil),
                        secondary: RateWindow(
                            usedPercent: 3,
                            windowMinutes: 10080,
                            resetsAt: staleWeeklyReset,
                            resetDescription: nil),
                        updatedAt: now.addingTimeInterval(-60))
                    : nil,
                error: nil,
                sourceLabel: "cached")
        }
        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: priorSnapshots)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        let sessionReset = now.addingTimeInterval(2 * 60 * 60)
        let weeklyReset = now.addingTimeInterval(2 * 24 * 60 * 60)
        let publicationGuard = CodexAccountScopedRefreshGuard(
            source: .managedAccount(id: targetID),
            identity: .providerAccount(id: "acct-current-target"),
            accountKey: "current@example.com")
        store.lastCodexUsagePublicationGuard = publicationGuard
        store.lastCodexAccountScopedRefreshGuard = publicationGuard
        store.lastKnownResetSnapshots[.codex] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 44,
                windowMinutes: 300,
                resetsAt: sessionReset,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 55,
                windowMinutes: 10080,
                resetsAt: weeklyReset,
                resetDescription: nil),
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "current@example.com",
                accountOrganization: nil,
                loginMethod: "Pro"))
        self.installContextualCodexProvider(on: store) { context in
            let isTarget = context.env["CODEX_HOME"] == targetHome.path
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: isTarget ? 4 : 9,
                    windowMinutes: 0,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now)
        }

        await store.refreshCodexVisibleAccountsForMenu()

        let targetSnapshot = try #require(store.codexAccountSnapshots.first {
            $0.account.workspaceAccountID == "acct-current-target"
        }?.snapshot)
        #expect(targetSnapshot.primary?.usedPercent == 4)
        #expect(targetSnapshot.primary?.windowMinutes == 300)
        #expect(targetSnapshot.primary?.resetsAt == sessionReset)
        #expect(targetSnapshot.secondary?.usedPercent == 55)
        #expect(targetSnapshot.secondary?.windowMinutes == 10080)
        #expect(targetSnapshot.secondary?.resetsAt == weeklyReset)
        #expect(store.snapshots[.codex]?.primary?.resetsAt == sessionReset)
        #expect(store.snapshots[.codex]?.secondary?.resetsAt == weeklyReset)
        #expect(snapshotStore.storedSnapshots.first {
            $0.account.workspaceAccountID == "acct-current-target"
        }?.snapshot?.secondary?.resetsAt == weeklyReset)
    }

    @Test
    func `ignores prior snapshot from same email different codex workspace`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountVisibleHistoryBackfillTests-prior-workspace")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let targetID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-888888888888"))
        let oldID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-999999999999"))
        let siblingID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-AAAAAAAAAAAA"))
        let targetHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-prior-target-\(UUID().uuidString)", isDirectory: true)
        let siblingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-prior-sibling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: targetHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingHome, withIntermediateDirectories: true)
        let targetAccount = ManagedCodexAccount(
            id: targetID,
            email: "prior@example.com",
            providerAccountID: "acct-prior-new",
            workspaceLabel: "New Team",
            workspaceAccountID: "acct-prior-new",
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let siblingAccount = ManagedCodexAccount(
            id: siblingID,
            email: "other-prior@example.com",
            providerAccountID: "acct-prior-sibling",
            workspaceLabel: "Sibling Team",
            workspaceAccountID: "acct-prior-sibling",
            managedHomePath: siblingHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let oldVisibleAccount = CodexVisibleAccount(
            id: "prior@example.com",
            email: "prior@example.com",
            workspaceLabel: "Old Team",
            workspaceAccountID: "acct-prior-old",
            storedAccountID: oldID,
            selectionSource: .managedAccount(id: oldID),
            isActive: false,
            isLive: false,
            canReauthenticate: false,
            canRemove: false)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [targetAccount, siblingAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: targetHome)
            try? FileManager.default.removeItem(at: siblingHome)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: targetID)

        let now = Date()
        let staleReset = now.addingTimeInterval(2 * 60 * 60)
        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [
            CodexAccountUsageSnapshot(
                account: oldVisibleAccount,
                snapshot: UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: 72,
                        windowMinutes: 300,
                        resetsAt: staleReset,
                        resetDescription: nil),
                    secondary: nil,
                    updatedAt: now,
                    identity: ProviderIdentitySnapshot(
                        providerID: .codex,
                        accountEmail: "prior@example.com",
                        accountOrganization: nil,
                        loginMethod: "Old Team")),
                error: nil,
                sourceLabel: "cached"),
        ])
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        self.installContextualCodexProvider(on: store) { context in
            let isTarget = context.env["CODEX_HOME"] == targetHome.path
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: isTarget ? 4 : 9,
                    windowMinutes: 0,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now)
        }

        await store.refreshCodexVisibleAccountsForMenu()

        let targetSnapshot = try #require(store.codexAccountSnapshots.first {
            $0.account.workspaceAccountID == "acct-prior-new"
        }?.snapshot)
        #expect(targetSnapshot.primary?.usedPercent == 4)
        #expect(targetSnapshot.primary?.windowMinutes == 0)
        #expect(targetSnapshot.primary?.resetsAt == nil)
        #expect(targetSnapshot.secondary == nil)
    }

    @Test
    func `ignores ambiguous email history for same email codex workspaces`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountVisibleHistoryBackfillTests-ambiguous-email-history")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let targetID = try #require(UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-111111111111"))
        let siblingID = try #require(UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-222222222222"))
        let targetHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-history-target-\(UUID().uuidString)", isDirectory: true)
        let siblingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-history-sibling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: targetHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingHome, withIntermediateDirectories: true)
        let targetAccount = ManagedCodexAccount(
            id: targetID,
            email: "history-shared@example.com",
            providerAccountID: "acct-history-target",
            workspaceLabel: "Target Team",
            workspaceAccountID: "acct-history-target",
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let siblingAccount = ManagedCodexAccount(
            id: siblingID,
            email: "history-shared@example.com",
            providerAccountID: "acct-history-sibling",
            workspaceLabel: "Sibling Team",
            workspaceAccountID: "acct-history-sibling",
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
        let now = Date()
        let normalizedEmail = try #require(CodexIdentityResolver.normalizeEmail("history-shared@example.com"))
        let emailHistoryKey = CodexHistoryOwnership.canonicalEmailHashKey(for: normalizedEmail)
        store.planUtilizationHistory[.codex] = PlanUtilizationHistoryBuckets(accounts: [
            emailHistoryKey: [
                planSeries(name: .session, windowMinutes: 300, entries: [
                    planEntry(at: now.addingTimeInterval(-60), usedPercent: 2, resetsAt: now.addingTimeInterval(3600)),
                ]),
                planSeries(name: .weekly, windowMinutes: 10080, entries: [
                    planEntry(
                        at: now.addingTimeInterval(-60),
                        usedPercent: 33,
                        resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60)),
                ]),
            ],
        ])
        self.installContextualCodexProvider(on: store) { context in
            let isTarget = context.env["CODEX_HOME"] == targetHome.path
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: isTarget ? 4 : 9,
                    windowMinutes: 0,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now)
        }

        await store.refreshCodexVisibleAccountsForMenu()

        let targetSnapshot = try #require(store.codexAccountSnapshots.first {
            $0.account.workspaceAccountID == "acct-history-target"
        }?.snapshot)
        #expect(targetSnapshot.primary?.usedPercent == 4)
        #expect(targetSnapshot.primary?.windowMinutes == 0)
        #expect(targetSnapshot.primary?.resetsAt == nil)
        #expect(targetSnapshot.secondary == nil)
        #expect(store.planUtilizationHistory[.codex]?.histories(for: emailHistoryKey).isEmpty == false)
    }

    @Test
    func `email only live codex row does not inherit prior quota windows`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountVisibleHistoryBackfillTests-live-prior")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let managedID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-111111111111"))
        let liveHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-live-prior-\(UUID().uuidString)", isDirectory: true)
        let managedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-live-prior-managed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: liveHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managedHome, withIntermediateDirectories: true)
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live-prior@example.com",
            codexHomePath: liveHome.path,
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "live-prior@example.com"))
        let managedAccount = ManagedCodexAccount(
            id: managedID,
            email: "managed-prior@example.com",
            providerAccountID: "acct-managed-prior",
            workspaceLabel: "Managed Team",
            workspaceAccountID: "acct-managed-prior",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: liveHome)
            try? FileManager.default.removeItem(at: managedHome)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: managedID)

        let now = Date()
        let priorReset = now.addingTimeInterval(2 * 60 * 60)
        let priorSnapshots = settings.codexVisibleAccountProjection.visibleAccounts.map { account in
            CodexAccountUsageSnapshot(
                account: account,
                snapshot: account.selectionSource == .liveSystem
                    ? UsageSnapshot(
                        primary: RateWindow(
                            usedPercent: 18,
                            windowMinutes: 300,
                            resetsAt: priorReset,
                            resetDescription: nil),
                        secondary: nil,
                        updatedAt: now.addingTimeInterval(-60))
                    : nil,
                error: nil,
                sourceLabel: "cached")
        }
        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: priorSnapshots)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        self.installContextualCodexProvider(on: store) { _ in
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 9,
                    windowMinutes: 0,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now)
        }

        await store.refreshCodexVisibleAccountsForMenu()

        let liveSnapshot = try #require(store.codexAccountSnapshots.first {
            $0.account.selectionSource == .liveSystem
        }?.snapshot)
        #expect(liveSnapshot.primary?.usedPercent == 9)
        #expect(liveSnapshot.primary?.windowMinutes == 0)
        #expect(liveSnapshot.primary?.resetsAt == nil)
    }

    @Test
    func `ignores live codex prior snapshot after auth fingerprint changes`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountVisibleHistoryBackfillTests-live-prior-auth-change")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let managedID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-222222222222"))
        let liveHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-live-prior-auth-\(UUID().uuidString)", isDirectory: true)
        let managedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-live-prior-auth-managed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: liveHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managedHome, withIntermediateDirectories: true)
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live-prior-auth@example.com",
            authFingerprint: "current-live-auth-fingerprint",
            codexHomePath: liveHome.path,
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "live-prior-auth@example.com"))
        let managedAccount = ManagedCodexAccount(
            id: managedID,
            email: "managed-prior-auth@example.com",
            providerAccountID: "acct-managed-prior-auth",
            workspaceLabel: "Managed Team",
            workspaceAccountID: "acct-managed-prior-auth",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: liveHome)
            try? FileManager.default.removeItem(at: managedHome)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: managedID)

        let now = Date()
        let priorReset = now.addingTimeInterval(2 * 60 * 60)
        let liveAccount = try #require(settings.codexVisibleAccountProjection.visibleAccounts.first {
            $0.selectionSource == .liveSystem
        })
        let priorLiveAccount = CodexVisibleAccount(
            id: liveAccount.id,
            email: liveAccount.email,
            workspaceLabel: liveAccount.workspaceLabel,
            workspaceAccountID: liveAccount.workspaceAccountID,
            authFingerprint: "stale-live-auth-fingerprint",
            storedAccountID: liveAccount.storedAccountID,
            selectionSource: liveAccount.selectionSource,
            isActive: liveAccount.isActive,
            isLive: liveAccount.isLive,
            canReauthenticate: liveAccount.canReauthenticate,
            canRemove: liveAccount.canRemove)
        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [
            CodexAccountUsageSnapshot(
                account: priorLiveAccount,
                snapshot: UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: 18,
                        windowMinutes: 300,
                        resetsAt: priorReset,
                        resetDescription: nil),
                    secondary: nil,
                    updatedAt: now.addingTimeInterval(-60)),
                error: nil,
                sourceLabel: "cached"),
        ])
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        self.installContextualCodexProvider(on: store) { _ in
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 9,
                    windowMinutes: 0,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now)
        }

        await store.refreshCodexVisibleAccountsForMenu()

        let liveSnapshot = try #require(store.codexAccountSnapshots.first {
            $0.account.selectionSource == .liveSystem
        }?.snapshot)
        #expect(liveSnapshot.primary?.usedPercent == 9)
        #expect(liveSnapshot.primary?.windowMinutes == 0)
        #expect(liveSnapshot.primary?.resetsAt == nil)
    }

    @Test
    func `ignores active reset cache and email history after live auth fingerprint changes`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountVisibleHistoryBackfillTests-live-active-auth-change")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let managedID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-333333333333"))
        let liveHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-live-active-auth-\(UUID().uuidString)", isDirectory: true)
        let managedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-live-active-auth-managed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: liveHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managedHome, withIntermediateDirectories: true)
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live-active-auth@example.com",
            authFingerprint: "current-live-active-auth",
            codexHomePath: liveHome.path,
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "live-active-auth@example.com"))
        let managedAccount = ManagedCodexAccount(
            id: managedID,
            email: "managed-active-auth@example.com",
            providerAccountID: "acct-managed-active-auth",
            workspaceLabel: "Managed Team",
            workspaceAccountID: "acct-managed-active-auth",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: liveHome)
            try? FileManager.default.removeItem(at: managedHome)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .liveSystem

        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [])
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        let now = Date()
        let staleSessionReset = now.addingTimeInterval(2 * 60 * 60)
        let staleWeeklyReset = now.addingTimeInterval(2 * 24 * 60 * 60)
        store.lastCodexAccountScopedRefreshGuard = CodexAccountScopedRefreshGuard(
            source: .liveSystem,
            identity: .emailOnly(normalizedEmail: "live-active-auth@example.com"),
            accountKey: "live-active-auth@example.com",
            authFingerprint: "stale-live-active-auth")
        store.lastKnownResetSnapshots[.codex] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 44,
                windowMinutes: 300,
                resetsAt: staleSessionReset,
                resetDescription: nil),
            secondary: nil,
            updatedAt: now.addingTimeInterval(-60),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "live-active-auth@example.com",
                accountOrganization: nil,
                loginMethod: nil))
        let emailHistoryKey = CodexHistoryOwnership.canonicalEmailHashKey(for: "live-active-auth@example.com")
        store.planUtilizationHistory[.codex] = PlanUtilizationHistoryBuckets(accounts: [
            emailHistoryKey: [
                planSeries(name: .session, windowMinutes: 300, entries: [
                    planEntry(at: now.addingTimeInterval(-60), usedPercent: 44, resetsAt: staleSessionReset),
                ]),
                planSeries(name: .weekly, windowMinutes: 10080, entries: [
                    planEntry(at: now.addingTimeInterval(-60), usedPercent: 55, resetsAt: staleWeeklyReset),
                ]),
            ],
        ])
        self.installContextualCodexProvider(on: store) { _ in
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 9,
                    windowMinutes: 0,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now)
        }

        await store.refreshCodexVisibleAccountsForMenu()

        let liveSnapshot = try #require(store.codexAccountSnapshots.first {
            $0.account.selectionSource == .liveSystem
        }?.snapshot)
        #expect(liveSnapshot.primary?.usedPercent == 9)
        #expect(liveSnapshot.primary?.windowMinutes == 0)
        #expect(liveSnapshot.primary?.resetsAt == nil)
        #expect(liveSnapshot.secondary == nil)
    }

    @Test
    func `stacked visible refresh skips selected apply after live auth fingerprint changes`() async throws {
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        let settings = self.makeSettingsStore(
            suite: "CodexAccountVisibleHistoryBackfillTests-selected-auth-change")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let managedID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-444444444444"))
        let liveHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-selected-auth-\(UUID().uuidString)", isDirectory: true)
        let managedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-selected-auth-managed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: liveHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managedHome, withIntermediateDirectories: true)
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "selected-auth@example.com",
            authFingerprint: "old-live-selected-auth",
            codexHomePath: liveHome.path,
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "selected-auth@example.com"))
        let managedAccount = ManagedCodexAccount(
            id: managedID,
            email: "managed-selected-auth@example.com",
            providerAccountID: "acct-managed-selected-auth",
            workspaceLabel: "Managed Team",
            workspaceAccountID: "acct-managed-selected-auth",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = nil
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: liveHome)
            try? FileManager.default.removeItem(at: managedHome)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .liveSystem
        let staleReconciliationSnapshot = settings.codexAccountReconciliationSnapshot

        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [])
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        let now = Date()
        let staleReset = now.addingTimeInterval(2 * 60 * 60)
        let priorDisplayedSnapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 11,
                windowMinutes: 300,
                resetsAt: staleReset,
                resetDescription: nil),
            secondary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "selected-auth@example.com",
                accountOrganization: nil,
                loginMethod: nil))
        store._setSnapshotForTesting(priorDisplayedSnapshot, provider: .codex)
        store.lastKnownResetSnapshots[.codex] = priorDisplayedSnapshot
        let priorGuard = store.currentCodexAccountScopedRefreshGuard(
            preferCurrentSnapshot: false)
        store.lastCodexUsagePublicationGuard = priorGuard
        store.lastCodexAccountScopedRefreshGuard = priorGuard
        let blocker = BlockingCodexFetchStrategy()
        let liveHomePath = liveHome.path
        self.installContextualCodexProvider(on: store) { context in
            if context.env["CODEX_HOME"] == liveHomePath {
                return try await blocker.awaitResult()
            }
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 7,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "managed-selected-auth@example.com",
                    accountOrganization: nil,
                    loginMethod: "Managed Team"))
        }

        let refreshTask = Task { await store.refreshCodexVisibleAccountsForMenu() }
        await blocker.waitUntilStarted()
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "selected-auth@example.com",
            authFingerprint: "new-live-selected-auth",
            codexHomePath: liveHome.path,
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "selected-auth@example.com"))
        settings.cachedCodexAccountReconciliationSnapshot = CachedCodexAccountReconciliationSnapshot(
            activeSource: .liveSystem,
            loadedAt: Date(),
            snapshot: staleReconciliationSnapshot)
        await blocker.resume(with: .success(UsageSnapshot(
            primary: RateWindow(
                usedPercent: 77,
                windowMinutes: 300,
                resetsAt: staleReset,
                resetDescription: nil),
            secondary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "selected-auth@example.com",
                accountOrganization: nil,
                loginMethod: nil))))
        await refreshTask.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.lastKnownResetSnapshots[.codex] == nil)
        #expect(!store.codexAccountSnapshots.contains {
            $0.account.selectionSource == .liveSystem
        })
        #expect(!snapshotStore.storedSnapshots.contains {
            $0.account.selectionSource == .liveSystem
        })
    }

    @Test
    func `stacked visible refresh keeps selected apply after live token fingerprint rotates`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountVisibleHistoryBackfillTests-selected-token-rotation")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let managedID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-888888888888"))
        let liveHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-selected-token-\(UUID().uuidString)", isDirectory: true)
        let managedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-selected-token-managed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: liveHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managedHome, withIntermediateDirectories: true)
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "selected-token@example.com",
            workspaceLabel: "Live Team",
            workspaceAccountID: "acct-selected-token",
            authFingerprint: "old-live-selected-token",
            codexHomePath: liveHome.path,
            observedAt: Date(),
            identity: .providerAccount(id: "acct-selected-token"))
        let managedAccount = ManagedCodexAccount(
            id: managedID,
            email: "managed-selected-token@example.com",
            providerAccountID: "acct-managed-selected-token",
            workspaceLabel: "Managed Team",
            workspaceAccountID: "acct-managed-selected-token",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: liveHome)
            try? FileManager.default.removeItem(at: managedHome)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .liveSystem

        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [])
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        let blocker = BlockingCodexFetchStrategy()
        let liveHomePath = liveHome.path
        let now = Date()
        let reset = now.addingTimeInterval(2 * 60 * 60)
        self.installContextualCodexProvider(on: store) { context in
            if context.env["CODEX_HOME"] == liveHomePath {
                return try await blocker.awaitResult()
            }
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 7,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "managed-selected-token@example.com",
                    accountOrganization: nil,
                    loginMethod: "Managed Team"))
        }

        let refreshTask = Task { await store.refreshCodexVisibleAccountsForMenu() }
        await blocker.waitUntilStarted()
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "selected-token@example.com",
            workspaceLabel: "Live Team",
            workspaceAccountID: "acct-selected-token",
            authFingerprint: "new-live-selected-token",
            codexHomePath: liveHome.path,
            observedAt: Date(),
            identity: .providerAccount(id: "acct-selected-token"))
        await blocker.resume(with: .success(UsageSnapshot(
            primary: RateWindow(
                usedPercent: 77,
                windowMinutes: 300,
                resetsAt: reset,
                resetDescription: nil),
            secondary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "selected-token@example.com",
                accountOrganization: nil,
                loginMethod: "Pro"))))
        await refreshTask.value

        let selectedSnapshot = try #require(store.snapshots[.codex])
        #expect(selectedSnapshot.primary?.usedPercent == 77)
        #expect(selectedSnapshot.accountEmail(for: .codex) == "selected-token@example.com")
        #expect(selectedSnapshot.loginMethod(for: .codex) == "Pro")
        #expect(store.lastCodexAccountScopedRefreshGuard?.authFingerprint == "new-live-selected-token")

        let liveRow = try #require(store.codexAccountSnapshots.first {
            $0.account.selectionSource == .liveSystem
        })
        #expect(liveRow.account.authFingerprint == "new-live-selected-token")
        #expect(liveRow.snapshot?.primary?.usedPercent == 77)

        let persistedLive = try #require(snapshotStore.storedSnapshots.first {
            $0.account.selectionSource == .liveSystem
        })
        #expect(persistedLive.account.authFingerprint == "new-live-selected-token")
        #expect(persistedLive.snapshot?.primary?.usedPercent == 77)
    }

    @Test
    func `stacked visible refresh clears selected state after live account email changes`() async throws {
        SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = 60
        let settings = self.makeSettingsStore(
            suite: "CodexAccountVisibleHistoryBackfillTests-selected-email-change")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let managedID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-777777777777"))
        let liveHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-selected-email-\(UUID().uuidString)", isDirectory: true)
        let managedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-selected-email-managed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: liveHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managedHome, withIntermediateDirectories: true)
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "old-selected@example.com",
            workspaceLabel: "Live Team",
            workspaceAccountID: "acct-selected-email",
            authFingerprint: "old-live-selected-email",
            codexHomePath: liveHome.path,
            observedAt: Date(),
            identity: .providerAccount(id: "acct-selected-email"))
        let managedAccount = ManagedCodexAccount(
            id: managedID,
            email: "managed-selected-email@example.com",
            providerAccountID: "acct-managed-selected-email",
            workspaceLabel: "Managed Team",
            workspaceAccountID: "acct-managed-selected-email",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            SettingsStore.codexAccountReconciliationSnapshotCacheIntervalOverrideForTesting = nil
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: liveHome)
            try? FileManager.default.removeItem(at: managedHome)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .liveSystem
        let staleReconciliationSnapshot = settings.codexAccountReconciliationSnapshot

        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [])
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        let now = Date()
        let staleReset = now.addingTimeInterval(2 * 60 * 60)
        let priorDisplayedSnapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 11,
                windowMinutes: 300,
                resetsAt: staleReset,
                resetDescription: nil),
            secondary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "old-selected@example.com",
                accountOrganization: nil,
                loginMethod: nil))
        store._setSnapshotForTesting(priorDisplayedSnapshot, provider: .codex)
        store.lastKnownResetSnapshots[.codex] = priorDisplayedSnapshot
        store.lastCodexAccountScopedRefreshGuard = store.currentCodexAccountScopedRefreshGuard(
            preferCurrentSnapshot: false)
        let blocker = BlockingCodexFetchStrategy()
        let liveHomePath = liveHome.path
        self.installContextualCodexProvider(on: store) { context in
            if context.env["CODEX_HOME"] == liveHomePath {
                return try await blocker.awaitResult()
            }
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 7,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "managed-selected-email@example.com",
                    accountOrganization: nil,
                    loginMethod: "Managed Team"))
        }

        let refreshTask = Task { await store.refreshCodexVisibleAccountsForMenu() }
        await blocker.waitUntilStarted()
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "new-selected@example.com",
            workspaceLabel: "Live Team",
            workspaceAccountID: "acct-selected-email",
            authFingerprint: "new-live-selected-email",
            codexHomePath: liveHome.path,
            observedAt: Date(),
            identity: .providerAccount(id: "acct-selected-email"))
        settings.cachedCodexAccountReconciliationSnapshot = CachedCodexAccountReconciliationSnapshot(
            activeSource: .liveSystem,
            loadedAt: Date(),
            snapshot: staleReconciliationSnapshot)
        await blocker.resume(with: .success(UsageSnapshot(
            primary: RateWindow(
                usedPercent: 77,
                windowMinutes: 300,
                resetsAt: staleReset,
                resetDescription: nil),
            secondary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "old-selected@example.com",
                accountOrganization: nil,
                loginMethod: nil))))
        await refreshTask.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.lastKnownResetSnapshots[.codex] == nil)
        #expect(!store.codexAccountSnapshots.contains {
            $0.account.selectionSource == .liveSystem
        })
        #expect(store.codexAccountSnapshots.contains {
            $0.account.workspaceAccountID == "acct-managed-selected-email"
        })
        #expect(!snapshotStore.storedSnapshots.contains {
            $0.account.selectionSource == .liveSystem
        })
        #expect(snapshotStore.storedSnapshots.contains {
            $0.account.workspaceAccountID == "acct-managed-selected-email"
        })
    }

    @Test
    func `stacked visible refresh discards selected apply after provider account email changes`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountVisibleHistoryBackfillTests-selected-provider-email-change")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let targetID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-555555555555"))
        let siblingID = try #require(UUID(uuidString: "DDDDDDDD-EEEE-FFFF-AAAA-666666666666"))
        let targetHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-provider-email-\(UUID().uuidString)", isDirectory: true)
        let siblingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-provider-email-sibling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: targetHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingHome, withIntermediateDirectories: true)
        let originalTarget = ManagedCodexAccount(
            id: targetID,
            email: "old-provider@example.com",
            providerAccountID: "acct-provider-email",
            workspaceLabel: "Provider Team",
            workspaceAccountID: "acct-provider-email",
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let updatedTarget = ManagedCodexAccount(
            id: targetID,
            email: "new-provider@example.com",
            providerAccountID: "acct-provider-email",
            workspaceLabel: "Provider Team",
            workspaceAccountID: "acct-provider-email",
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 3,
            lastAuthenticatedAt: 3)
        let siblingAccount = ManagedCodexAccount(
            id: siblingID,
            email: "sibling-provider@example.com",
            providerAccountID: "acct-provider-sibling",
            workspaceLabel: "Sibling Team",
            workspaceAccountID: "acct-provider-sibling",
            managedHomePath: siblingHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [originalTarget, siblingAccount])
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
        let reset = now.addingTimeInterval(90 * 60)
        let prior = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 63,
                windowMinutes: 300,
                resetsAt: reset,
                resetDescription: nil),
            secondary: nil,
            updatedAt: now.addingTimeInterval(-60),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "old-provider@example.com",
                accountOrganization: nil,
                loginMethod: "Provider Team"))
        let priorGuard = CodexAccountScopedRefreshGuard(
            source: .managedAccount(id: targetID),
            identity: .providerAccount(id: "acct-provider-email"),
            accountKey: "old-provider@example.com")
        store.snapshots[.codex] = prior
        store.lastKnownResetSnapshots[.codex] = prior
        store.lastCodexUsagePublicationGuard = priorGuard
        store.lastCodexAccountScopedRefreshGuard = priorGuard
        self.installContextualCodexProvider(on: store) { context in
            if context.env["CODEX_HOME"] == targetHomePath {
                return try await blocker.awaitResult()
            }
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 11,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "sibling-provider@example.com",
                    accountOrganization: nil,
                    loginMethod: "Sibling Team"))
        }

        let refreshTask = Task { await store.refreshCodexVisibleAccountsForMenu() }
        await blocker.waitUntilStarted()
        try FileManagedCodexAccountStore(fileURL: storeURL).storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [updatedTarget, siblingAccount]))
        await blocker.resume(with: .success(UsageSnapshot(
            primary: RateWindow(
                usedPercent: 64,
                windowMinutes: 300,
                resetsAt: reset,
                resetDescription: nil),
            secondary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "old-provider@example.com",
                accountOrganization: nil,
                loginMethod: "Pro"))))
        await refreshTask.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.lastKnownResetSnapshots[.codex] == nil)
        #expect(!store.codexAccountSnapshots.contains {
            $0.account.workspaceAccountID == "acct-provider-email"
        })
        #expect(store.codexAccountSnapshots.contains {
            $0.account.workspaceAccountID == "acct-provider-sibling"
        })
        #expect(!snapshotStore.storedSnapshots.contains {
            $0.account.workspaceAccountID == "acct-provider-email"
        })
    }
}
