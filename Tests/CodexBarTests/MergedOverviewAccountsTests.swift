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
    func `overview claude card follows the swap account the claude tab presents`() async throws {
        try await ClaudeSwapRichUsageFixture.withFixture { fixture in
            let store = fixture.store
            store.errors[.claude] = "Claude usage probe timed out."
            store.snapshots[.claude] = nil
            #expect(!store.settings.mergedOverviewAllAccounts)
            guard let active = fixture.accounts.first(where: { $0.isActive }) else {
                Issue.record("Expected an active Claude swap account")
                return
            }

            for layout in [MultiAccountMenuLayout.segmented, .stacked] {
                store.settings.multiAccountMenuLayout = layout
                let rows = store.mergedOverviewRows(for: [.claude])
                #expect(rows.count == 1)
                let row = try #require(rows.first)
                // A provider row, so Overview keeps its submenu, storage line, and row identity.
                #expect(row.accountID == nil)
                #expect(row.model?.subtitleText.localizedCaseInsensitiveContains("probe timed out") != true)
                #expect(row.model?.metrics.first?.percent == 26)
            }

            // Below the presentation threshold the ambient card stays.
            store.claudeSwapAccountSnapshots = [active]
            store.errors[.claude] = nil
            store.snapshots[.claude] = UsageSnapshot(
                primary: RateWindow(usedPercent: 42, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date())
            #expect(store.mergedOverviewRows(for: [.claude]).first?.model?.metrics.first?.percent == 42)
            store.settings.claudeSwapShowSingleAccount = true
            #expect(store.mergedOverviewRows(for: [.claude]).first?.model?.metrics.first?.percent == 26)
        }
    }

    @Test
    func `overview retains inspected Claude account details with or without an active slot`() async throws {
        try await ClaudeSwapRichUsageFixture.withFixture { fixture in
            let store = fixture.store
            store.settings.multiAccountMenuLayout = .segmented
            let inspectedCandidate = fixture.accounts.first { !$0.isActive && !$0.canActivate }
            let inspected = try #require(inspectedCandidate)

            let inactiveAccounts: [ProviderAccountUsageSnapshot] = fixture.accounts.filter { !$0.isActive }
            for accounts in [fixture.accounts, inactiveAccounts] {
                store.claudeSwapAccountSnapshots = accounts
                let rows = store.mergedOverviewRows(for: [.claude], claudeSwapInspectedAccountID: inspected.id)
                #expect(rows.count == 1)
                let row = try #require(rows.first)
                #expect(row.accountID == nil)
                #expect(row.model?.email == inspected.displayLabel)
                #expect(row.model?.metrics.first?.percent == inspected.snapshot?.primary?.usedPercent)
            }

            // A removed inspection must not hide the current active account.
            store.claudeSwapAccountSnapshots = fixture.accounts.filter { $0.id != inspected.id }
            let fallback = store.mergedOverviewRows(for: [.claude], claudeSwapInspectedAccountID: inspected.id)
            #expect(fallback.first?.model?.metrics.first?.percent == 26)
        }
    }

    @Test
    func `single Claude overview card keeps swap identity private and separate from Codex`() async throws {
        try await ClaudeSwapRichUsageFixture.withFixture { fixture in
            let store = fixture.store
            store.snapshots[.codex] = UsageSnapshot(
                primary: RateWindow(usedPercent: 91, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "codex@example.invalid",
                    accountOrganization: nil,
                    loginMethod: "Codex fixture plan"))
            let rows = store.mergedOverviewRows(for: [.codex, .claude])
            let claude = try #require(rows.first { $0.provider == .claude }?.model)
            #expect(claude.email == "Primary")
            #expect(claude.metrics.first?.percent == 26)
            #expect(claude.planText?.contains("Codex fixture plan") != true)
            #expect(rows.first { $0.provider == .codex }?.model?.metrics.first?.percent == 91)

            store.settings.hidePersonalInfo = true
            let hidden = try #require(store.mergedOverviewRows(for: [.claude]).first?.model)
            #expect(hidden.email == "Account 1")
            #expect(hidden.metrics.first?.percent == 26)
        }
    }

    @Test
    func `overview claude swap card keeps the provider row local costs`() async throws {
        try await ClaudeSwapRichUsageFixture.withFixture { fixture in
            let store = fixture.store
            store.settings.costUsageEnabled = true
            store._setTokenSnapshotForTesting(CostUsageTokenSnapshot(
                sessionTokens: 123,
                sessionCostUSD: 0.12,
                last30DaysTokens: 123,
                last30DaysCostUSD: 1.23,
                daily: [
                    CostUsageDailyReport.Entry(
                        date: "2026-11-01",
                        inputTokens: nil,
                        outputTokens: nil,
                        totalTokens: 123,
                        costUSD: 1.23,
                        modelsUsed: nil,
                        modelBreakdowns: nil),
                ],
                updatedAt: Date()), provider: .claude)

            let row = store.mergedOverviewRows(for: [.claude]).first
            #expect(row?.model?.metrics.first?.percent == 26)
            #expect(row?.model?.tokenUsage != nil)

            // "All accounts" rows stay per-account and keep omitting provider-wide costs.
            store.settings.mergedOverviewAllAccounts = true
            #expect(store.mergedOverviewRows(for: [.claude]).allSatisfy { $0.model?.tokenUsage == nil })
        }
    }

    @Test
    func `overview keeps the ambient claude card when the swap list has no presented account`() async throws {
        try await ClaudeSwapRichUsageFixture.withFixture { fixture in
            let store = fixture.store
            store.claudeSwapAccountSnapshots = fixture.accounts.filter { !$0.isActive }
            #expect(store.claudeSwapAccountSnapshots.count > 1)
            store.snapshots[.claude] = UsageSnapshot(
                primary: RateWindow(usedPercent: 42, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date())

            let rows = store.mergedOverviewRows(for: [.claude])
            #expect(rows.count == 1)
            #expect(rows.first?.accountID == nil)
            #expect(rows.first?.model?.metrics.first?.percent == 42)
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
