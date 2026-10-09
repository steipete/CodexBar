import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

private actor OverviewFetchRecorder {
    var workspaceIDs: [String] = []

    func record(_ id: String) {
        self.workspaceIDs.append(id)
    }
}

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `overview retains every inventory row and never borrows selected account data`() async throws {
        try await self.withSelectedAccountRetentionFixture(sameEmail: true, count: 8) { store, _, accounts in
            store.codexAccountSnapshots.removeAll { $0.id == accounts[7].id }
            let recorder = OverviewFetchRecorder()
            self.installOverviewProvider(on: store, accounts: accounts, recorder: recorder)
            let capturedDates = store.codexAccountSnapshots.map { $0.snapshot?.updatedAt }
            let source = store.settings.codexActiveSource
            let overview = try #require(store.codexAccountUsageOverview(onRefresh: { _ in }))
            #expect(overview.rows.count == 8)
            #expect(overview.rows.filter(\.isFollowed).map(\.id) == [accounts[0].id])
            #expect(overview.rows.filter(\.isSystem).isEmpty)
            let unavailable = try #require(overview.rows.first { $0.id == accounts[7].id })
            #expect(unavailable.model.metrics.isEmpty)
            #expect(unavailable.model.planText == nil)
            #expect(unavailable.model.creditsText == nil)
            #expect(unavailable.updatedAt == nil)
            #expect(overview.rows.allSatisfy { $0.model.tokenUsage == nil })
            #expect(overview.rows.first { $0.id == accounts[1].id }?.error != nil)
            #expect(store.settings.codexActiveSource == source)
            #expect(await recorder.workspaceIDs.isEmpty)
            #expect(store.codexAccountSnapshots.map { $0.snapshot?.updatedAt } == capturedDates)
        }
    }

    @Test(arguments: [0, 1])
    func `zero and one account retain the single account settings presentation`(count: Int) async throws {
        try await self.withSelectedAccountRetentionFixture(sameEmail: false, count: count) { store, _, accounts in
            #expect(store.settings.codexVisibleAccountProjection.visibleAccounts.count == count)
            #expect(store.codexAccountUsageOverview(onRefresh: { _ in }) == nil)
            if let account = accounts.first {
                store.snapshots[.codex] = store.codexAccountSnapshots.first?.snapshot
                let model = store.menuCardModel(for: .codex, context: .settings)
                #expect(model.email == account.email)
                #expect(!model.metrics.isEmpty)
            }
        }
    }

    @Test
    func `overview privacy labels stay distinct across same email workspaces`() async throws {
        try await self.withSelectedAccountRetentionFixture(sameEmail: true) { store, _, _ in
            store.settings.hidePersonalInfo = true
            store.codexAccountSnapshots = store.codexAccountSnapshots.map { record in
                CodexAccountUsageSnapshot(
                    account: record.account,
                    snapshot: record.snapshot,
                    error: "Failed for shared@example.com",
                    sourceLabel: "oauth shared@example.com",
                    credits: record.credits)
            }
            let overview = try #require(store.codexAccountUsageOverview(onRefresh: { _ in }))
            #expect(Set(overview.rows.map(\.title)).count == 2)
            #expect(overview.rows.allSatisfy { !$0.title.contains("@") && !$0.model.email.contains("@") })
            #expect(overview.rows.allSatisfy { $0.error?.contains("@") == false })
            #expect(overview.rows.allSatisfy { $0.sourceLabel?.contains("@") == false })
        }
    }

    @Test
    func `settings refreshes one sibling without changing followed usage or credentials`() async throws {
        try await self.withSelectedAccountRetentionFixture(sameEmail: true) { store, snapshotStore, accounts in
            let selected = try #require(store.codexAccountSnapshots.first { $0.id == accounts[0].id }?.snapshot)
            store.snapshots[.codex] = selected
            let source = store.settings.codexActiveSource
            let systemAuthURL = try URL(fileURLWithPath: #require(store.environmentBase["CODEX_HOME"]))
                .appendingPathComponent("auth.json")
            let systemAuthBefore = try? Data(contentsOf: systemAuthURL)
            let metadata = try FileManagedCodexAccountStore(
                fileURL: #require(store.settings._test_managedCodexAccountStoreURL)).loadAccountMetadata()
            let authFiles = try metadata.accounts.map {
                try Data(contentsOf: URL(fileURLWithPath: $0.managedHomePath).appendingPathComponent("auth.json"))
            }
            let recorder = OverviewFetchRecorder()
            self.installOverviewProvider(on: store, accounts: accounts, recorder: recorder)

            await store.refreshCodexAccountsForSettings([accounts[1].id])
            await store.widgetSnapshotPersistTask?.value

            #expect(await recorder.workspaceIDs == accounts[1...1].compactMap(\.workspaceAccountID))
            #expect(store.settings.codexActiveSource == source)
            #expect(store.snapshots[.codex]?.updatedAt == selected.updatedAt)
            #expect(store.snapshots[.codex]?.primary == selected.primary)
            #expect(store.codexAccountSnapshots.count == 2)
            #expect(snapshotStore.load(for: accounts).first { $0.id == accounts[1].id }?.snapshot?.primary?
                .usedPercent == 77)
            #expect(store.codexSettingsRefreshingAccountIDs.isEmpty)
            #expect((try? Data(contentsOf: systemAuthURL)) == systemAuthBefore)
            for (index, account) in metadata.accounts.enumerated() {
                #expect(try Data(contentsOf: URL(fileURLWithPath: account.managedHomePath)
                        .appendingPathComponent("auth.json")) == authFiles[index])
            }
        }
    }

    @Test
    func `refresh all batches every account beyond the menu limit`() async throws {
        try await self
            .withSelectedAccountRetentionFixture(sameEmail: true, count: 8) { store, snapshotStore, accounts in
                let source = store.settings.codexActiveSource
                let recorder = OverviewFetchRecorder()
                self.installOverviewProvider(on: store, accounts: accounts, recorder: recorder)

                await store.refreshCodexAccountsForSettings(Set(accounts.map(\.id)))
                await store.widgetSnapshotPersistTask?.value

                let fetched = await recorder.workspaceIDs
                #expect(fetched.count == 8)
                #expect(Set(fetched) == Set(accounts.compactMap(\.workspaceAccountID)))
                #expect(store.codexAccountSnapshots.count == 8)
                #expect(snapshotStore.load(for: accounts).allSatisfy { $0.snapshot?.primary?.usedPercent == 77 })
                #expect(store.settings.codexActiveSource == source)
            }
    }

    @Test
    func `failed sibling refresh preserves its age and leaves followed errors alone`() async throws {
        try await self.withSelectedAccountRetentionFixture(sameEmail: false) { store, _, accounts in
            let previous = try #require(store.codexAccountSnapshots.first { $0.id == accounts[1].id })
            self.installContextualCodexProvider(on: store, sourceLabel: "oauth", kind: .oauth) { _ in
                throw URLError(.notConnectedToInternet)
            }
            await store.refreshCodexAccountsForSettings([accounts[1].id])
            await store.widgetSnapshotPersistTask?.value
            let refreshed = try #require(store.codexAccountSnapshots.first { $0.id == accounts[1].id })
            #expect(refreshed.snapshot?.updatedAt == previous.snapshot?.updatedAt)
            #expect(refreshed.error != nil)
            #expect(store.errors[.codex] == nil)
            #expect(store.codexAccountSnapshots.count == 2)
        }
    }

    @Test
    func `overview shows first refresh failure after managed credentials rotate`() async throws {
        try await self.withSelectedAccountRetentionFixture(sameEmail: false) { store, _, accounts in
            let sibling = accounts[1]
            let metadata = try FileManagedCodexAccountStore(
                fileURL: #require(store.settings._test_managedCodexAccountStoreURL)).loadAccountMetadata()
            let profile = try #require(metadata.accounts.first { $0.id == sibling.storedAccountID })
            let authURL = CodexAuthFingerprint.authFileURL(homePath: profile.managedHomePath)
            let originalAuth = try Data(contentsOf: authURL)
            var rotatedAuth = originalAuth
            rotatedAuth.append(0x0A)
            try rotatedAuth.write(to: authURL)
            store.codexAccountSnapshots.removeAll { $0.id == sibling.id }
            let source = store.settings.codexActiveSource
            self.installContextualCodexProvider(on: store, sourceLabel: "oauth", kind: .oauth) { _ in
                throw CodexOAuthFetchError.unauthorized
            }

            await store.refreshCodexAccountsForSettings([sibling.id])
            await store.widgetSnapshotPersistTask?.value

            let failure = try #require(store.codexAccountSnapshots.first { $0.id == sibling.id })
            #expect(failure.error != nil)
            #expect(failure.snapshot == nil)
            #expect(failure.account.authFingerprint != sibling.authFingerprint)
            var overview = try #require(store.codexAccountUsageOverview(onRefresh: { _ in }))
            var row = try #require(overview.rows.first { $0.id == sibling.id })
            try self.writeRotatedAuthOverviewProof(overview, phase: "failed-refresh")
            #expect(row.error == CodexUIErrorMapper.userFacingMessage(failure.error))
            #expect(row.model.metrics.isEmpty)
            #expect(overview.rows.first { $0.id == accounts[0].id }?.error == nil)
            #expect(store.settings.codexActiveSource == source)

            // Once credentials change again, the failure no longer belongs to their current owner.
            try originalAuth.write(to: authURL)
            store.settings.invalidateCodexAccountReconciliationSnapshotCache()
            overview = try #require(store.codexAccountUsageOverview(onRefresh: { _ in }))
            row = try #require(overview.rows.first { $0.id == sibling.id })
            try self.writeRotatedAuthOverviewProof(overview, phase: "rotated-again")
            #expect(row.error == nil)
            #expect(row.model.metrics.isEmpty)
        }
    }

    private func installOverviewProvider(
        on store: UsageStore,
        accounts: [CodexVisibleAccount],
        recorder: OverviewFetchRecorder)
    {
        self.installContextualCodexProvider(on: store, sourceLabel: "oauth", kind: .oauth) { context in
            let workspace = try #require(context.codexWorkspaceID)
            await recorder.record(workspace)
            let account = try #require(accounts.first { $0.workspaceAccountID == workspace })
            return UsageSnapshot(
                primary: RateWindow(usedPercent: 77, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: account.email,
                    accountOrganization: nil,
                    loginMethod: "Pro",
                    accountID: workspace))
        }
    }

    @Test
    func `settings rejects a suspended result after followed account changes`() async throws {
        try await self.withSelectedAccountRetentionFixture(sameEmail: true) { store, _, accounts in
            let previous = try #require(store.codexAccountSnapshots.first { $0.id == accounts[1].id })
            let settings = store.settings
            let newSource = accounts[1].selectionSource
            self.installContextualCodexProvider(on: store, sourceLabel: "oauth", kind: .oauth) { context in
                await MainActor.run { settings.codexActiveSource = newSource }
                return UsageSnapshot(
                    primary: RateWindow(usedPercent: 99, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                    secondary: nil,
                    updatedAt: Date(),
                    identity: ProviderIdentitySnapshot(
                        providerID: .codex,
                        accountEmail: accounts[1].email,
                        accountOrganization: nil,
                        loginMethod: "Pro",
                        accountID: context.codexWorkspaceID))
            }
            await store.refreshCodexAccountsForSettings([accounts[1].id])
            await store.widgetSnapshotPersistTask?.value
            #expect(store.codexAccountSnapshots.first { $0.id == accounts[1].id }?.snapshot?.updatedAt
                == previous.snapshot?.updatedAt)
            #expect(store.codexSettingsRefreshingAccountIDs.isEmpty)
        }
    }

    @Test
    func `ambient PAT mode does not attribute one token to visible accounts`() async throws {
        try await self.withSelectedAccountRetentionFixture(sameEmail: false) { store, _, accounts in
            store.settings.codexUsageDataSource = .pat
            let recorder = OverviewFetchRecorder()
            self.installOverviewProvider(on: store, accounts: accounts, recorder: recorder)
            #expect(store.codexAccountUsageOverview(onRefresh: { _ in }) == nil)
            await store.refreshCodexAccountsForSettings(Set(accounts.map(\.id)))
            #expect(await recorder.workspaceIDs.isEmpty)
        }
    }

    @Test
    func `followed errors appear only under their verified account owner`() async throws {
        try await self.withSelectedAccountRetentionFixture(sameEmail: true) { store, _, accounts in
            store.errors[.codex] = "Selected account failed"
            store.lastCodexUsagePublicationGuard = UsageStore.codexScopedRefreshGuard(for: accounts[0])
            var overview = try #require(store.codexAccountUsageOverview(onRefresh: { _ in }))
            #expect(overview.rows.first { $0.id == accounts[0].id }?.error == "Selected account failed")
            #expect(overview.rows.first { $0.id == accounts[1].id }?.error == "Network error")

            store.lastCodexUsagePublicationGuard = UsageStore.codexScopedRefreshGuard(for: accounts[1])
            overview = try #require(store.codexAccountUsageOverview(onRefresh: { _ in }))
            #expect(overview.rows.first { $0.id == accounts[0].id }?.error == nil)
        }
    }

    @Test(arguments: [false, true])
    func `settings header refreshes followed usage once with dashboard enrichment`(sameEmail: Bool) async throws {
        try await self.withSelectedAccountRetentionFixture(sameEmail: sameEmail) { store, _, accounts in
            store.settings.openAIWebAccessEnabled = true
            store.settings.codexCookieSource = .auto
            let recorder = OverviewFetchRecorder()
            self.installOverviewProvider(on: store, accounts: accounts, recorder: recorder)

            var creditsCalled = false
            store._test_codexCreditsLoaderOverride = {
                creditsCalled = true
                return self.credits(remaining: 42)
            }
            var dashboardCalled = false
            store._test_openAIDashboardLoaderOverride = { _, _, _, _ in
                dashboardCalled = true
                return OpenAIDashboardSnapshot(
                    signedInEmail: accounts[0].email,
                    accountID: accounts[0].workspaceAccountID,
                    codeReviewRemainingPercent: 88,
                    creditEvents: [],
                    dailyBreakdown: [],
                    usageBreakdown: [],
                    creditsPurchaseURL: nil,
                    creditsRemaining: 42,
                    updatedAt: Date())
            }
            defer {
                store._test_codexCreditsLoaderOverride = nil
                store._test_openAIDashboardLoaderOverride = nil
            }

            await store.refreshCodexAccountScopedState(allowDisabled: true)
            let fetched = await recorder.workspaceIDs
            #expect(fetched == accounts.prefix(1).compactMap(\.workspaceAccountID))
            #expect(creditsCalled)
            #expect(dashboardCalled)
            #expect(!store.openAIDashboardRequiresLogin)
            #expect(store.openAIDashboard?.accountID == accounts[0].workspaceAccountID)
            let overview = try #require(store.codexAccountUsageOverview(onRefresh: { _ in }))
            let followed = try #require(overview.rows.first { $0.isFollowed })
            let liveReview = store.menuCardModel(for: .codex, context: .settings)
                .metrics.first { $0.id == "code-review" }
            if sameEmail {
                #expect(liveReview == nil)
                #expect(!followed.model.metrics.contains { $0.id == "code-review" })
            } else {
                let review = try #require(liveReview)
                #expect(followed.model.metrics.first { $0.id == "code-review" }?.percent == review.percent)
            }
            #expect(overview.rows.filter { !$0.isFollowed }.allSatisfy { row in
                !row.model.metrics.contains { $0.id == "code-review" }
            })
            store.lastCodexUsagePublicationGuard = UsageStore.codexScopedRefreshGuard(for: accounts[1])
            let mismatched = try #require(store.codexAccountUsageOverview(onRefresh: { _ in }))
            #expect(mismatched.rows.allSatisfy { row in !row.model.metrics.contains { $0.id == "code-review" } })
        }
    }
}
