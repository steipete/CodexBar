import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test(arguments: [false, true])
    func `selected account refresh preserves sibling usage on disk`(sameEmail: Bool) async throws {
        try await self.withSelectedAccountRetentionFixture(sameEmail: sameEmail) { store, snapshotStore, accounts in
            let sibling = try #require(store.codexAccountSnapshots.first { $0.id == accounts[1].id })
            #expect(!store.shouldFetchAllCodexVisibleAccounts())
            let selection = store.settings.codexActiveSource

            await store.refreshProvider(.codex, allowDisabled: true)
            await store.widgetSnapshotPersistTask?.value

            #expect(store.settings.codexActiveSource == selection)
            #expect(store.codexAccountSnapshots.count == 2)
            let retained = try #require(store.codexAccountSnapshots.first { $0.id == sibling.id })
            #expect(retained.snapshot?.updatedAt == sibling.snapshot?.updatedAt)
            #expect(retained.snapshot?.primary == sibling.snapshot?.primary)
            #expect(retained.error == sibling.error)
            #expect(retained.credits?.remaining == sibling.credits?.remaining)
            let restarted = self.makeUsageStore(settings: store.settings, codexAccountUsageSnapshotStore: snapshotStore)
            #expect(restarted.codexAccountSnapshots.count == 2)
            #expect(restarted.codexAccountSnapshots.first { $0.id == sibling.id }?.snapshot?.updatedAt
                == sibling.snapshot?.updatedAt)
            let reloaded = snapshotStore.load(for: accounts)
            #expect(reloaded.count == 2)
            #expect(reloaded.first { $0.id == sibling.id }?.snapshot?.updatedAt == sibling.snapshot?.updatedAt)
            #expect(reloaded.first { $0.id == accounts[0].id }?.snapshot?.primary?.usedPercent == 42)
        }
    }

    @Test
    func `selected account refresh prunes deleted siblings instead of resurrecting them`() async throws {
        try await self.withSelectedAccountRetentionFixture(sameEmail: false) { store, snapshotStore, accounts in
            let metadataURL = try #require(store.settings._test_managedCodexAccountStoreURL)
            let metadata = FileManagedCodexAccountStore(fileURL: metadataURL)
            let saved = try metadata.loadAccountMetadata()
            try metadata.storeAccounts(ManagedCodexAccountSet(
                version: saved.version,
                accounts: saved.accounts.filter { $0.id == accounts[0].storedAccountID }))
            store.settings.invalidateCodexAccountReconciliationSnapshotCache()

            await store.refreshProvider(.codex, allowDisabled: true)
            await store.widgetSnapshotPersistTask?.value

            #expect(store.codexAccountSnapshots.map(\.id) == [accounts[0].id])
            #expect(snapshotStore.load(for: accounts).map(\.id) == [accounts[0].id])
        }
    }

    @Test(arguments: [false, true])
    func `selected account failure leaves sibling cache intact`(transportFailure: Bool) async throws {
        try await self.withSelectedAccountRetentionFixture(sameEmail: true) { store, snapshotStore, accounts in
            let sibling = try #require(store.codexAccountSnapshots.first { $0.id == accounts[1].id })
            self.installContextualCodexProvider(on: store, sourceLabel: "oauth", kind: .oauth) { _ in
                if transportFailure { throw URLError(.notConnectedToInternet) }
                throw CodexOAuthFetchError.unauthorized
            }

            await store.refreshProvider(.codex, allowDisabled: true)
            await store.widgetSnapshotPersistTask?.value

            let retained = try #require(store.codexAccountSnapshots.first { $0.id == sibling.id })
            #expect(retained.snapshot?.updatedAt == sibling.snapshot?.updatedAt)
            #expect(retained.error == sibling.error)
            #expect(retained.credits?.remaining == sibling.credits?.remaining)
            #expect(store.codexAccountSnapshots.contains { $0.id == accounts[0].id } == transportFailure)
            #expect(snapshotStore.load(for: accounts).first { $0.id == sibling.id }?.snapshot?.updatedAt
                == sibling.snapshot?.updatedAt)
        }
    }

    func withSelectedAccountRetentionFixture(
        sameEmail: Bool,
        count: Int = 2,
        body: (UsageStore, FileCodexAccountUsageSnapshotStore, [CodexVisibleAccount]) async throws -> Void)
        async throws
    {
        let root = CodexCredentialFixtures.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = self.makeSettingsStore(suite: "SelectedSnapshotRetention-\(UUID().uuidString)")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .segmented
        settings.accountWidgetsEnabled = false
        settings.codexUsageDataSource = .oauth
        settings.codexCookieSource = .off
        let saved = try (0..<count).map { index in
            let email = sameEmail ? "shared@example.com" : "account-\(index)@example.com"
            let home = root.appendingPathComponent("home-\(index)", isDirectory: true)
            let workspace = "workspace-\(index)"
            try Self.writeCodexAuthFile(homeURL: home, email: email, plan: "Pro", accountId: workspace)
            return ManagedCodexAccount(
                id: UUID(),
                email: email,
                providerAccountID: workspace,
                workspaceLabel: "Workspace \(index)",
                workspaceAccountID: workspace,
                authFingerprint: CodexAuthFingerprint.fingerprint(homePath: home.path),
                managedHomePath: home.path,
                createdAt: 1,
                updatedAt: 2,
                lastAuthenticatedAt: 2)
        }
        let metadataURL = root.appendingPathComponent("accounts.json")
        try FileManagedCodexAccountStore(fileURL: metadataURL).storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion, accounts: saved))
        settings._test_managedCodexAccountStoreURL = metadataURL
        settings.codexActiveSource = saved.first.map { .managedAccount(id: $0.id) } ?? .liveSystem
        let accounts = try saved.map { saved in
            try #require(settings.codexVisibleAccountProjection.visibleAccounts
                .first { $0.storedAccountID == saved.id })
        }
        let snapshotStore = FileCodexAccountUsageSnapshotStore(fileURL: root.appendingPathComponent("snapshots.json"))
        let prior = Date().addingTimeInterval(-600)
        snapshotStore.store(accounts.map { account in
            CodexAccountUsageSnapshot(
                account: account,
                snapshot: UsageSnapshot(
                    primary: RateWindow(usedPercent: 17, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                    secondary: nil,
                    updatedAt: prior,
                    identity: ProviderIdentitySnapshot(
                        providerID: .codex,
                        accountEmail: account.email,
                        accountOrganization: nil,
                        loginMethod: "Pro",
                        accountID: account.workspaceAccountID)),
                error: account.id == accounts.dropFirst().first?.id ? "Network error" : nil,
                sourceLabel: "oauth",
                credits: CreditsSnapshot(remaining: 12, events: [], updatedAt: prior))
        })
        let store = self.makeUsageStore(settings: settings, codexAccountUsageSnapshotStore: snapshotStore)
        store._test_widgetSnapshotSaveOverride = { _ in }
        store._test_codexResetCreditsFetcherOverride = { _ in nil }
        self.installContextualCodexProvider(on: store, sourceLabel: "oauth", kind: .oauth) { _ in
            let selected = try #require(saved.first)
            return UsageSnapshot(
                primary: RateWindow(usedPercent: 42, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: selected.email,
                    accountOrganization: nil,
                    loginMethod: "Pro",
                    accountID: selected.effectiveWorkspaceAccountID))
        }
        try await body(store, snapshotStore, accounts)
        await store.widgetSnapshotPersistTask?.value
    }
}
