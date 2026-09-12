import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `account scoped refresh keeps selected workspace ownership through credits`() async throws {
        let suite = "CodexManagedWorkspaceRefreshTests-account-scoped-credits"
        let root = CodexCredentialFixtures.root
            .appendingPathComponent("managed-workspace-account-refresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let targetHome = root.appendingPathComponent("target", isDirectory: true)
        let siblingHome = root.appendingPathComponent("sibling", isDirectory: true)
        let authenticatedTarget = try self.makeManagedCodexWeeklyPublicationAccount(
            id: UUID(),
            email: "workspace-member@example.com",
            workspaceID: "auth-default-workspace",
            workspaceLabel: "Default",
            homeURL: targetHome)
        let target = ManagedCodexAccount(
            id: authenticatedTarget.id,
            email: authenticatedTarget.email,
            providerAccountID: "selected-team-workspace",
            workspaceLabel: "Selected Team",
            workspaceAccountID: nil,
            authFingerprint: authenticatedTarget.authFingerprint,
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let sibling = try self.makeManagedCodexWeeklyPublicationAccount(
            id: UUID(),
            email: "sibling@example.com",
            workspaceID: "sibling-workspace",
            workspaceLabel: "Sibling",
            homeURL: siblingHome)
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [target, sibling])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: storeURL)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: target.id)
        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [])
        let store = self.makeCodexWeeklyPublicationStore(
            settings: settings,
            suite: suite,
            snapshotStore: snapshotStore)
        let publishedCredits = self.credits(remaining: 42)
        let targetSnapshot = self.codexSnapshot(email: target.email, usedPercent: 64)
        let siblingSnapshot = self.codexSnapshot(email: sibling.email, usedPercent: 22)
        store._test_codexCreditsLoaderOverride = { publishedCredits }
        defer { store._test_codexCreditsLoaderOverride = nil }
        self.installContextualCodexProvider(on: store) { context in
            switch context.env["CODEX_HOME"] {
            case targetHome.path:
                #expect(context.codexWorkspaceID == "selected-team-workspace")
                return targetSnapshot
            case siblingHome.path:
                return siblingSnapshot
            default:
                throw TestRefreshError(message: "Unexpected Codex home")
            }
        }

        await store.refreshCodexAccountScopedState(allowDisabled: true)

        #expect(store.snapshots[.codex]?.primary?.usedPercent == 64)
        #expect(store.lastCodexUsagePublicationGuard?.identity == .providerAccount(id: "selected-team-workspace"))
        #expect(store.lastCodexAccountScopedRefreshGuard?.identity == .providerAccount(id: "selected-team-workspace"))
        #expect(store.credits?.remaining == 42)
        #expect(store.codexAccountSnapshots.first { $0.account.storedAccountID == target.id }?.credits?.remaining == 42)
        #expect(snapshotStore.storedSnapshots.first { $0.account.storedAccountID == target.id }?.credits?
            .remaining == 42)
    }

    @Test
    func `workspace switch changes credits key and rejects the in flight result`() async throws {
        let suite = "CodexManagedWorkspaceRefreshTests-credits-workspace-switch"
        let root = CodexCredentialFixtures.root
            .appendingPathComponent("managed-workspace-credits-switch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let targetHome = root.appendingPathComponent("target", isDirectory: true)
        let authenticatedTarget = try self.makeManagedCodexWeeklyPublicationAccount(
            id: UUID(),
            email: "workspace-member@example.com",
            workspaceID: "auth-default-workspace",
            workspaceLabel: "Default",
            homeURL: targetHome)
        let target = ManagedCodexAccount(
            id: authenticatedTarget.id,
            email: authenticatedTarget.email,
            providerAccountID: "selected-team-workspace",
            workspaceLabel: "Selected Team",
            workspaceAccountID: nil,
            authFingerprint: authenticatedTarget.authFingerprint,
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [target])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_codexReconciliationEnvironment = nil
            try? FileManager.default.removeItem(at: storeURL)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: target.id)
        let store = self.makeCodexWeeklyPublicationStore(settings: settings, suite: suite)
        let blocker = BlockingCreditsLoader()
        store._test_codexCreditsLoaderOverride = { try await blocker.awaitResult() }
        defer { store._test_codexCreditsLoaderOverride = nil }
        let initialGuard = store.freshCodexAccountScopedRefreshGuard()
        let initialKey = store.codexCreditsRefreshKey(expectedGuard: initialGuard)

        let refresh = Task { await store.refreshCreditsIfNeeded() }
        await blocker.waitUntilStarted()
        let replacement = ManagedCodexAccount(
            id: target.id,
            email: target.email,
            providerAccountID: "replacement-team-workspace",
            workspaceLabel: "Replacement Team",
            workspaceAccountID: nil,
            authFingerprint: target.authFingerprint,
            managedHomePath: target.managedHomePath,
            createdAt: target.createdAt,
            updatedAt: 3,
            lastAuthenticatedAt: target.lastAuthenticatedAt)
        try FileManagedCodexAccountStore(fileURL: storeURL).storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [replacement]))
        let replacementGuard = store.freshCodexAccountScopedRefreshGuard()
        let replacementKey = store.codexCreditsRefreshKey(expectedGuard: replacementGuard)
        await blocker.resumeNext(with: .success(self.credits(remaining: 42)))
        await refresh.value

        #expect(initialGuard.identity == .providerAccount(id: "selected-team-workspace"))
        #expect(replacementGuard.identity == .providerAccount(id: "replacement-team-workspace"))
        #expect(initialKey != replacementKey)
        #expect(store.credits == nil)
        #expect(store.lastCreditsSnapshot == nil)
    }

    @Test(arguments: [false, true])
    func `failed workspace switch never republishes prior workspace credits`(
        dataNotAvailableFailure: Bool) async throws
    {
        let suite = "CodexManagedWorkspaceRefreshTests-failed-credits-switch-\(dataNotAvailableFailure)"
        let root = CodexCredentialFixtures.root
            .appendingPathComponent("managed-workspace-failed-credits-switch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let targetHome = root.appendingPathComponent("target", isDirectory: true)
        let authenticatedTarget = try self.makeManagedCodexWeeklyPublicationAccount(
            id: UUID(),
            email: "workspace-member@example.com",
            workspaceID: "auth-default-workspace",
            workspaceLabel: "Default",
            homeURL: targetHome)
        let firstWorkspace = ManagedCodexAccount(
            id: authenticatedTarget.id,
            email: authenticatedTarget.email,
            workspaceLabel: "First Team",
            workspaceAccountID: "first-team-workspace",
            authFingerprint: authenticatedTarget.authFingerprint,
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [firstWorkspace])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: firstWorkspace.id)
        let store = self.makeCodexWeeklyPublicationStore(settings: settings, suite: suite)
        let cachedCredits = self.credits(remaining: 42)
        store._test_codexCreditsLoaderOverride = { cachedCredits }
        defer { store._test_codexCreditsLoaderOverride = nil }
        let firstGuard = store.freshCodexAccountScopedRefreshGuard()

        await store.refreshCreditsIfNeeded()

        #expect(firstWorkspace.providerAccountID == nil)
        #expect(firstGuard.identity == .providerAccount(id: "first-team-workspace"))
        #expect(store.credits == cachedCredits)
        #expect(store.lastCreditsSnapshotOwnerGuard == firstGuard)

        let secondWorkspace = ManagedCodexAccount(
            id: firstWorkspace.id,
            email: firstWorkspace.email,
            workspaceLabel: "Second Team",
            workspaceAccountID: "second-team-workspace",
            authFingerprint: firstWorkspace.authFingerprint,
            managedHomePath: firstWorkspace.managedHomePath,
            createdAt: firstWorkspace.createdAt,
            updatedAt: 3,
            lastAuthenticatedAt: firstWorkspace.lastAuthenticatedAt)
        try FileManagedCodexAccountStore(fileURL: storeURL).storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: [secondWorkspace]))
        let secondGuard = store.freshCodexAccountScopedRefreshGuard()
        let failureMessage = dataNotAvailableFailure
            ? "Codex credits data not available yet"
            : "Second workspace credits failed"
        store._test_codexCreditsLoaderOverride = {
            throw TestRefreshError(message: failureMessage)
        }

        await store.refreshCreditsIfNeeded()

        #expect(secondWorkspace.providerAccountID == nil)
        #expect(secondGuard.identity == .providerAccount(id: "second-team-workspace"))
        #expect(store.codexCreditsRefreshKey(expectedGuard: firstGuard) !=
            store.codexCreditsRefreshKey(expectedGuard: secondGuard))
        #expect(store.credits == nil)
        #expect(store.lastCreditsSnapshot == cachedCredits)
        #expect(store.lastCreditsSnapshotOwnerGuard == firstGuard)
        #expect(store.lastCreditsError == (dataNotAvailableFailure
                ? "Codex credits are still loading; will retry shortly."
                : failureMessage))
    }

    @Test(arguments: [false, true], [false, true])
    func `stacked refresh keeps selected managed workspace separate from auth default`(
        switchesWorkspaceDuringRefresh: Bool,
        usesProviderAccountIDFallback: Bool) async throws
    {
        let suite = "CodexManagedWorkspaceRefreshTests-\(switchesWorkspaceDuringRefresh)-" +
            "\(usesProviderAccountIDFallback)"
        let root = CodexCredentialFixtures.root
            .appendingPathComponent("managed-workspace-refresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let targetHome = root.appendingPathComponent("target", isDirectory: true)
        let siblingHome = root.appendingPathComponent("sibling", isDirectory: true)
        let authenticatedTarget = try self.makeManagedCodexWeeklyPublicationAccount(
            id: UUID(),
            email: "workspace-member@example.com",
            workspaceID: "auth-default-workspace",
            workspaceLabel: "Default",
            homeURL: targetHome)
        let target = ManagedCodexAccount(
            id: authenticatedTarget.id,
            email: authenticatedTarget.email,
            providerAccountID: "selected-team-workspace",
            workspaceLabel: "Selected Team",
            workspaceAccountID: usesProviderAccountIDFallback ? nil : "selected-team-workspace",
            authFingerprint: authenticatedTarget.authFingerprint,
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let sibling = try self.makeManagedCodexWeeklyPublicationAccount(
            id: UUID(),
            email: "sibling-member@example.com",
            workspaceID: "sibling-workspace",
            workspaceLabel: "Sibling",
            homeURL: siblingHome)
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [target, sibling])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: target.id)
        let initialProjection = settings.codexVisibleAccountProjection
        let initialTarget = try #require(initialProjection.visibleAccounts.first { $0.storedAccountID == target.id })
        #expect(initialTarget.workspaceAccountID == "selected-team-workspace")
        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [])
        let store = self.makeCodexWeeklyPublicationStore(
            settings: settings,
            suite: suite,
            snapshotStore: snapshotStore)
        let targetSnapshot = self.codexSnapshot(email: target.email, usedPercent: 64)
        let siblingSnapshot = self.codexSnapshot(email: sibling.email, usedPercent: 22)
        let blocker = BlockingCodexFetchStrategy()
        self.installContextualCodexProvider(on: store) { context in
            if context.env["CODEX_HOME"] == targetHome.path {
                #expect(context.codexWorkspaceID == "selected-team-workspace")
                return try await blocker.awaitResult()
            }
            #expect(context.env["CODEX_HOME"] == siblingHome.path)
            #expect(context.codexWorkspaceID == "sibling-workspace")
            return siblingSnapshot
        }

        let refresh = Task { await store.refreshCodexVisibleAccountsForMenu() }
        await blocker.waitUntilStarted()
        if switchesWorkspaceDuringRefresh {
            let replacement = ManagedCodexAccount(
                id: target.id,
                email: target.email,
                providerAccountID: "replacement-team-workspace",
                workspaceLabel: "Replacement Team",
                workspaceAccountID: usesProviderAccountIDFallback ? nil : "replacement-team-workspace",
                authFingerprint: target.authFingerprint,
                managedHomePath: target.managedHomePath,
                createdAt: target.createdAt,
                updatedAt: 3,
                lastAuthenticatedAt: target.lastAuthenticatedAt)
            try FileManagedCodexAccountStore(fileURL: storeURL).storeAccounts(ManagedCodexAccountSet(
                version: FileManagedCodexAccountStore.currentVersion,
                accounts: [replacement, sibling]))
        }
        await blocker.resume(with: .success(targetSnapshot))
        await refresh.value

        let menuProjection = try #require(settings.codexVisibleAccountProjectionForMenuDisplay)
        let displayedSnapshots = store.codexAccountSnapshots.filter { row in
            menuProjection.visibleAccounts.contains { account in
                account.id == row.id && UsageStore.codexPriorSnapshotAccountMatches(row.account, account: account)
            }
        }
        #expect(displayedSnapshots.contains {
            $0.account.storedAccountID == sibling.id && $0.snapshot?.primary?.usedPercent == 22
        })
        if switchesWorkspaceDuringRefresh {
            #expect(store.snapshots[.codex] == nil)
            #expect(!store.codexAccountSnapshots.contains { $0.account.storedAccountID == target.id })
            #expect(!snapshotStore.storedSnapshots.contains { $0.account.storedAccountID == target.id })
        } else {
            #expect(displayedSnapshots.count == 2)
            let targetRow = try #require(displayedSnapshots.first { $0.account.storedAccountID == target.id })
            #expect(targetRow.account.workspaceAccountID == "selected-team-workspace")
            #expect(targetRow.snapshot?.primary?.usedPercent == 64)
            #expect(store.snapshots[.codex]?.primary?.usedPercent == 64)
            #expect(snapshotStore.storedSnapshots.contains {
                $0.account.storedAccountID == target.id && $0.account.workspaceAccountID == "selected-team-workspace"
            })
        }
        let auth = try CodexOAuthCredentialsStore.load(env: ["CODEX_HOME": targetHome.path])
        #expect(auth.accountId == "auth-default-workspace")
    }
}
