import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ClaudeSwapAccountPrivacyTests {
    private let now = Date(timeIntervalSince1970: 1_782_000_000)

    @Test
    func `cards and compact rows keep source slots across account reordering`() throws {
        let rows = [
            self.row(9, alias: "Private alias"),
            self.row(2, active: true),
            self.row(7, unavailable: true),
            self.row(12),
        ]
        for orderedRows in [rows, Array(rows.reversed())] {
            let accounts = ClaudeSwapAccountProjection.accountSnapshots(
                from: .init(activeAccountNumber: 2, accounts: orderedRows),
                now: self.now)
            #expect(accounts.first { $0.id.opaqueID == "7" }?.snapshot == nil)
            for orderedAccounts in [accounts, Array(accounts.reversed())] {
                for account in orderedAccounts {
                    let hidden = try self.card(for: account, hidePersonalInfo: true)
                    let revealed = try self.card(for: account, hidePersonalInfo: false)
                    #expect(hidden.email == "Account \(account.id.opaqueID)")
                    #expect(revealed.email == account.displayLabel)
                    #expect(hidden.metrics.map(\.percent) == revealed.metrics.map(\.percent))
                    #expect(ClaudeSwapAccountMenuDisplay.label(for: account, hidePersonalInfo: true) == hidden.email)
                }
                let compact = try self.compactModels(for: orderedAccounts, hidePersonalInfo: true)
                #expect(Set(compact.map(\.label)) == ["Account 7", "Account 9", "Account 12"])
                for model in compact {
                    #expect(model.accessibilityText.contains(model.label))
                    #expect(!model.accessibilityText.contains("Private"))
                    #expect(!model.accessibilityText.contains("shared@example.com"))
                }
            }
        }
    }

    @Test(arguments: ["owner@corp", "\"owner\"@example.com", "o'connor@example.com", "Private Person · Private Org"])
    func `privacy replaces complete identities and arbitrary aliases`(label: String) throws {
        let account = self.account(slot: "7", label: label)
        let hidden = try self.card(for: account, hidePersonalInfo: true)
        let revealed = try self.card(for: account, hidePersonalInfo: false)
        #expect(hidden.email == "Account 7")
        #expect(revealed.email == label)
        #expect(hidden.heightFingerprint(section: "card") != revealed.heightFingerprint(section: "card"))

        let accounts = [
            self.account(slot: "2", label: "Active alias", active: true), account,
            self.account(slot: "9", label: "Other alias"), self.account(slot: "12", label: "Final alias"),
        ]
        let hiddenRows = try self.compactModels(for: accounts, hidePersonalInfo: true)
        let revealedRows = try self.compactModels(for: accounts, hidePersonalInfo: false)
        let hiddenRow = try #require(hiddenRows.first { $0.label == "Account 7" })
        let revealedRow = try #require(revealedRows.first { $0.label == label })
        #expect(hiddenRow.heightFingerprint != revealedRow.heightFingerprint)
        #expect(hiddenRow.detailLines == revealedRow.detailLines)
        #expect(hiddenRow.hasError == revealedRow.hasError)
        #expect(hiddenRow.accessibilityText.contains("Account 7"))
        #expect(!hiddenRow.accessibilityText.contains(label))
    }

    @Test
    func `other account sources retain whole value privacy redaction`() throws {
        for (provider, source) in [
            (UsageProvider.codex, "codex-account"), (.claude, "token-account"), (.cursor, "token-account"),
        ] {
            let accounts = (1...4).map { slot in
                self.account(
                    slot: String(slot),
                    label: "Private Person \(slot)",
                    provider: provider,
                    source: source,
                    active: slot == 1)
            }
            for account in accounts {
                #expect(ClaudeSwapAccountMenuDisplay.privacyOrdinal(for: account) == nil)
                #expect(try self.card(for: account, hidePersonalInfo: true).email.isEmpty)
                #expect(try self.card(for: account, hidePersonalInfo: false).email == account.displayLabel)
            }
            let models = try self.compactModels(for: accounts, hidePersonalInfo: true)
            #expect(models.count == 3)
            #expect(models.allSatisfy { $0.label.isEmpty && !$0.accessibilityText.contains("Private Person") })
        }
    }

    @Test(arguments: ["0", "-1", "owner@corp", "7 · Private Org", "92233720368547758070"])
    func `invalid source slots never become privacy labels`(slot: String) throws {
        let account = self.account(slot: slot, label: "Private alias")
        #expect(ClaudeSwapAccountMenuDisplay.privacyOrdinal(for: account) == nil)
        #expect(ClaudeSwapAccountMenuDisplay.label(for: account, hidePersonalInfo: true).isEmpty)
        #expect(try self.card(for: account, hidePersonalInfo: true).email.isEmpty)
    }

    @Test
    func `numeric identities from another provider do not grant a source ordinal`() {
        let account = self.account(slot: "7", label: "Private alias", provider: .codex)
        #expect(ClaudeSwapAccountMenuDisplay.privacyOrdinal(for: account) == nil)
    }

    private func row(
        _ slot: Int,
        alias: String? = nil,
        active: Bool = false,
        unavailable: Bool = false) -> ClaudeSwapAccountRow
    {
        ClaudeSwapAccountRow(
            number: slot,
            email: "shared@example.com",
            organizationName: "Private Org",
            alias: alias,
            isActive: active,
            usageStatus: unavailable ? .tokenExpired : .ok,
            fiveHour: unavailable ? nil : .init(usedPercent: 90, resetsAt: self.now.addingTimeInterval(3600)),
            sevenDay: nil)
    }

    private func account(
        slot: String,
        label: String,
        provider: UsageProvider = .claude,
        source: String = "claude-swap",
        active: Bool = false) -> ProviderAccountUsageSnapshot
    {
        ProviderAccountUsageSnapshot(
            id: .init(source: source, opaqueID: slot),
            provider: provider,
            displayLabel: label,
            isActive: active,
            canActivate: false,
            snapshot: nil,
            error: "Usage unavailable",
            sourceLabel: source)
    }

    private func card(
        for account: ProviderAccountUsageSnapshot,
        hidePersonalInfo: Bool) throws -> UsageMenuCardView.Model
    {
        let context: UsageMenuCardContext.Account = if account.provider == .claude,
                                                       account.id.source == ClaudeSwapAccountProjection.sourceName
        {
            try #require(ClaudeSwapAccountMenuDisplay.cardContext(
                for: account,
                planLabel: nil,
                adapterError: nil,
                switchError: nil).account)
        } else {
            .init(
                snapshot: account.snapshot,
                error: account.error,
                info: AccountInfo(email: account.displayLabel, plan: nil),
                sourceLabel: account.sourceLabel)
        }
        return try UsageMenuCardView.Model.make(.init(
            provider: account.provider,
            metadata: #require(ProviderDefaults.metadata[account.provider]),
            snapshot: context.snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: #require(context.info),
            accountIsAuthoritative: true,
            accountPrivacyOrdinal: context.privacyOrdinal,
            isRefreshing: false,
            lastError: context.error,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: false,
            sourceLabel: context.sourceLabel,
            hidePersonalInfo: hidePersonalInfo,
            now: self.now))
    }

    private func compactModels(
        for accounts: [ProviderAccountUsageSnapshot],
        hidePersonalInfo: Bool) throws -> [MenuCardCompactAccountRowView.Model]
    {
        try AccountMenuLayoutPlanner.plan(accounts: accounts, healthyTailExpanded: true).rows.compactMap { row in
            guard case let .compact(row) = row else { return nil }
            let account = try #require(accounts.first { $0.id == row.accountID })
            return MenuCardCompactAccountRowView.Model(
                row: row,
                resetTimeDisplayStyle: .countdown,
                hidePersonalInfo: hidePersonalInfo,
                privacyOrdinal: ClaudeSwapAccountMenuDisplay.privacyOrdinal(for: account),
                now: self.now)
        }
    }
}
