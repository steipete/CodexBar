import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MergedOverviewAccountsTests {
    @Test
    func `all accounts defaults off and persists without changing provider selection`() {
        let defaults = InMemoryUserDefaults()
        let config = testConfigStore(suiteName: "MergedOverviewAccountsTests")
        let settings = ProviderUsageItemVisibilityTests.settings(defaults: defaults, configStore: config)
        #expect(!settings.mergedOverviewAllAccounts)
        let providers: [ProviderInstanceID] = [.claude, .codex, .gemini, .cursor, .zai, .copilot, .kiro]
        let before = settings.resolvedMergedOverviewProviders(activeProviders: providers)
        settings.mergedOverviewAllAccounts = true
        #expect(ProviderUsageItemVisibilityTests.settings(defaults: defaults, configStore: config)
            .mergedOverviewAllAccounts)
        #expect(before.count == SettingsStore.mergedOverviewProviderLimit)
        #expect(settings.resolvedMergedOverviewProviders(activeProviders: providers) == before)
        settings.setMergedOverviewProviderSelection(provider: .codex, isSelected: false, activeProviders: providers)
        #expect(!settings.resolvedMergedOverviewProviders(activeProviders: providers).contains(.codex))
    }

    @Test
    func `token rows use saved order and account caches even with segmented menus`() async throws {
        try await ClaudeSwapRichUsageFixture.withFixture { fixture in
            let store = fixture.store
            store.claudeSwapAccountSnapshots = []
            store.settings.multiAccountMenuLayout = .segmented
            for label in ["First", "Second", "Not fetched"] {
                store.settings.addTokenAccount(provider: .claude, label: label, token: "fixture-\(label)")
            }
            let accounts = store.settings.tokenAccounts(for: .claude)
            let selectedID = store.settings.selectedTokenAccount(for: .claude)?.id
            store.accountSnapshots[.claude] = accounts.prefix(2).enumerated().map { index, account in
                TokenAccountUsageSnapshot(
                    account: account,
                    snapshot: UsageSnapshot(
                        primary: RateWindow(
                            usedPercent: Double(10 + index * 20),
                            windowMinutes: 300,
                            resetsAt: nil,
                            resetDescription: nil),
                        secondary: nil,
                        updatedAt: Date()),
                    error: nil,
                    sourceLabel: "fixture",
                    cacheKey: store.tokenAccountSnapshotCacheKey(provider: .claude, account: account))
            }
            store.snapshots[.claude] = store.accountSnapshots[.claude]?.first?.snapshot
            #expect(store.mergedOverviewRows(for: [.claude]).count == 1)
            store.settings.mergedOverviewAllAccounts = true
            let rows = store.mergedOverviewRows(for: [.claude])
            #expect(rows.map(\.accountID) == accounts.map(\.id.uuidString))
            #expect(rows.compactMap(\.model).map(\.email) == accounts.map(\.displayName))
            #expect(rows[0].model?.metrics.first?.percent == 10)
            #expect(rows[1].model?.metrics.first?.percent == 30)
            #expect(rows[2].model?.metrics.isEmpty == true)
            #expect(store.settings.selectedTokenAccount(for: .claude)?.id == selectedID)
            #expect(store.refreshingProviders.isEmpty)
        }
    }

    @Test
    func `claude adapters take precedence over saved token accounts and keep privacy`() async throws {
        try await ClaudeSwapRichUsageFixture.withFixture { fixture in
            let store = fixture.store
            store.settings.addTokenAccount(provider: .claude, label: "Saved A", token: "fixture-a")
            store.settings.addTokenAccount(provider: .claude, label: "Saved B", token: "fixture-b")
            store.settings.mergedOverviewAllAccounts = true
            let rows = store.mergedOverviewRows(for: [.claude])
            #expect(rows.count == fixture.accounts.count)
            #expect(rows.map(\.accountID) == fixture.accounts.map { $0.id.source + ":" + $0.id.opaqueID })
            #expect(rows.allSatisfy { $0.provider == .claude })
            store.settings.hidePersonalInfo = true
            let privateRows = store.mergedOverviewRows(for: [.claude])
            for account in fixture.accounts {
                if let email = account.accountEmail {
                    #expect(privateRows.allSatisfy { $0.model?.email.contains(email) != true })
                }
            }
            #expect(MergedOverviewRow.providerID(from: rows[0].id) == .claude)
            #expect(MergedOverviewRow.providerID(from: "codex") == .codex)

            store.claudeSwapAccountSnapshots = fixture.accounts.map { account in
                ProviderAccountUsageSnapshot(
                    id: ProviderAccountIdentity(source: "tcr", opaqueID: account.id.opaqueID),
                    provider: .claude,
                    displayLabel: account.displayLabel,
                    accountEmail: account.accountEmail,
                    isActive: false,
                    snapshot: account.snapshot,
                    error: account.error,
                    sourceLabel: "tcr")
            }
            let tcrRows = store.mergedOverviewRows(for: [.claude])
            #expect(tcrRows.count == fixture.accounts.count)
            #expect(tcrRows.allSatisfy { $0.accountID?.hasPrefix("tcr:") == true })
        }
    }
}

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `merged overview retains every cached managed account without borrowing live usage`() async throws {
        try await self.withSelectedAccountRetentionFixture(sameEmail: true, count: 8) { store, _, accounts in
            store.settings.mergedOverviewAllAccounts = true
            store.codexAccountSnapshots.removeAll { $0.id == accounts[7].id }
            store.snapshots[.codex] = store.codexAccountSnapshots.first?.snapshot
            let selected = store.settings.codexActiveSource
            let rows = store.mergedOverviewRows(for: [.codex])
            #expect(rows.count == 8)
            #expect(Set(rows.compactMap { $0.model?.email }).count == 8)
            #expect(Set(rows.compactMap(\.accountID)) == Set(accounts.map(\.id)))
            let missing = try #require(rows.first { $0.accountID == accounts[7].id })
            #expect(missing.model?.metrics.isEmpty == true)
            #expect(store.settings.codexActiveSource == selected)
            #expect(store.refreshingProviders.isEmpty)
            store.settings.hidePersonalInfo = true
            let privateRows = store.mergedOverviewRows(for: [.codex])
            #expect(Set(privateRows.compactMap { $0.model?.email }).count == 8)
            #expect(privateRows.allSatisfy { $0.model?.email.contains("@") == false })
        }
    }
}
