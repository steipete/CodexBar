import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
extension CodexAccountScopedRefreshTests {
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
