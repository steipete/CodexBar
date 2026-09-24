import CodexBarCore
import Foundation
import Testing
@testable import CodexBarWidget

@MainActor
struct WidgetAccountsOverviewTests {
    @Test
    func `multi account widget filters by enabled provider and keeps active account`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let active = self.account(slot: "2", active: true, used: 44, now: now)
        let inactive = self.account(slot: "1", active: false, used: 20, now: now)
        let entries = [inactive, active].map { account in
            WidgetSnapshot.AccountEntry(
                id: account.id.opaqueID,
                provider: .claude,
                label: "Account \(account.id.opaqueID)",
                usage: account.snapshot.map { snapshot in
                    WidgetSnapshot.ProviderEntry(
                        provider: .claude,
                        updatedAt: snapshot.updatedAt,
                        primary: snapshot.primary,
                        secondary: nil,
                        tertiary: nil,
                        creditsRemaining: nil,
                        codeReviewRemainingPercent: nil,
                        tokenUsage: nil,
                        dailyUsage: [])
                },
                isActive: account.isActive)
        }
        let snapshot = WidgetSnapshot(entries: [], accounts: entries, enabledProviders: [.claude], generatedAt: now)
        let visible = CodexBarAccountsWidgetView.accounts(in: snapshot, for: .claude)
        #expect(visible.count == 2)
        #expect(visible.first?.isActive == true)
        #expect(visible.map(\.usage?.primary?.usedPercent) == [44, 20])
        #expect(CodexBarAccountsWidgetView.accounts(in: snapshot, for: .codex).isEmpty)
        let disabled = WidgetSnapshot(entries: [], accounts: entries, enabledProviders: [], generatedAt: now)
        #expect(CodexBarAccountsWidgetView.accounts(in: disabled, for: .claude).isEmpty)

        let spendOnly = WidgetSnapshot.ProviderEntry(
            provider: .claude,
            updatedAt: now,
            primary: nil,
            secondary: nil,
            tertiary: nil,
            usageRows: [.init(
                id: "extraUsage",
                title: "Extra usage",
                percentLeft: 0,
                window: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil))],
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
        let spendMetrics = CodexBarAccountsWidgetView.metrics(for: spendOnly)
        #expect(spendMetrics.first?.title == "Extra usage")
        #expect(spendMetrics.first?.percentLeft == 0)
    }

    @Test
    func `selected account remains visible beyond medium and large row limits`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for count in [3, 6] {
            let entries = (1...count).map { slot in
                WidgetSnapshot.AccountEntry(
                    id: String(slot),
                    provider: .claude,
                    label: "Account \(slot)",
                    usage: nil,
                    isActive: slot == count)
            }
            let snapshot = WidgetSnapshot(
                entries: [],
                accounts: entries,
                enabledProviders: [.claude],
                generatedAt: now)
            let ordered = CodexBarAccountsWidgetView.accounts(in: snapshot, for: .claude)
            #expect(ordered.count == count)
            #expect(ordered.first?.id == String(count))
            #expect(ordered.prefix(count == 3 ? 2 : 5).contains { $0.isActive })
            #expect(ordered.dropFirst().map(\.id) == (1..<count).map(String.init))
        }
    }

    private func usage(used: Double, now: Date) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: used, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: now)
    }

    private func account(slot: String, active: Bool, used: Double?, now: Date) -> ProviderAccountUsageSnapshot {
        ProviderAccountUsageSnapshot(
            id: ProviderAccountIdentity(source: "claude-swap", opaqueID: slot),
            provider: .claude,
            displayLabel: "Account \(slot)",
            accountEmail: "account\(slot)@example.test",
            isActive: active,
            snapshot: used.map { self.usage(used: $0, now: now) },
            error: nil,
            sourceLabel: "claude-swap")
    }
}
