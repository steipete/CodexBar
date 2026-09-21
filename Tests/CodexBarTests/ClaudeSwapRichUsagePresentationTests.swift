import CodexBarCore
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI

@MainActor
struct ClaudeSwapRichUsagePresentationTests {
    @Test
    func `compact rows retain last known age in visible and accessible details`() async throws {
        try await ClaudeSwapRichUsageFixture.withFixture { fixture in
            let plan = AccountMenuLayoutPlanner.plan(accounts: fixture.accounts)
            let row = try #require(plan.rows.compactMap { item -> AccountMenuLayoutPlanner.CompactRow? in
                guard case let .compact(row) = item, row.accountID.opaqueID == "2" else { return nil }
                return row
            }.first)
            let account = try #require(fixture.accounts.first { $0.id == row.accountID })
            let model = MenuCardCompactAccountRowView.Model(
                row: row,
                resetTimeDisplayStyle: .countdown,
                hidePersonalInfo: true,
                privacyOrdinal: ClaudeSwapAccountMenuDisplay.privacyOrdinal(for: account),
                now: ClaudeSwapRichUsageFixture.now)
            #expect(model.label == "Account 2")
            #expect(model.accessibilityText.contains("Account 2"))
            #expect(!model.accessibilityText.contains("Research"))
            #expect(model.headroomPercent == 38)
            #expect(model.hasError)
            #expect(model.detailLines.contains { $0.contains("last-known usage") })
            #expect(model.accessibilityText.contains("last-known usage"))
            #expect(model.accessibilityText.contains("Account unavailable"))
            let later = MenuCardCompactAccountRowView.Model(
                row: row,
                resetTimeDisplayStyle: .countdown,
                now: ClaudeSwapRichUsageFixture.now.addingTimeInterval(3600))
            #expect(later.detailLines != model.detailLines)
            #expect(later.headroomPercent == model.headroomPercent)
        }
    }

    @Test
    func `last known accounts are never recommended or folded into a ready group without an error`() {
        let window = RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
        let snapshot = UsageSnapshot(
            primary: window,
            secondary: nil,
            updatedAt: ClaudeSwapRichUsageFixture.now.addingTimeInterval(-3600))
        var accounts: [ProviderAccountUsageSnapshot] = []
        for slot in 1...4 {
            let identity = ProviderAccountIdentity(source: "fixture", opaqueID: String(slot))
            let isActive = slot == 1
            let account = ProviderAccountUsageSnapshot(
                id: identity,
                provider: UsageProvider.claude,
                displayLabel: "Account \(slot)",
                isActive: isActive,
                canActivate: !isActive,
                usesLastKnownUsage: !isActive,
                snapshot: snapshot,
                error: nil,
                sourceLabel: "fixture")
            accounts.append(account)
        }
        let rows = AccountMenuLayoutPlanner.plan(accounts: accounts).rows
        #expect(rows.count == 4)
        let compact = rows.compactMap { item -> AccountMenuLayoutPlanner.CompactRow? in
            guard case let .compact(row) = item else { return nil }
            return row
        }
        #expect(compact.count == 3)
        #expect(compact.allSatisfy { !$0.isBestCandidate && $0.lastKnownUsageCapturedAt != nil })
    }

    @Test
    func `terminal cards retain the capture time and diagnostic beside last known numbers`() async throws {
        try await ClaudeSwapRichUsageFixture.withFixture { fixture in
            let account = try #require(fixture.accounts.first { $0.id.opaqueID == "2" })
            let captured = try #require(account.snapshot?.updatedAt)
            let card = CLICardsRenderer.makeClaudeSwapCard(
                account: account,
                renderOptions: .init(
                    status: nil,
                    useColor: false,
                    resetStyle: .countdown,
                    weeklyWorkDays: nil,
                    now: ClaudeSwapRichUsageFixture.now))
            #expect(card.metrics.count == 2)
            #expect(card.accountProblem?.contains("Token expired") == true)
            #expect(card.infoLines
                .contains { $0.contains("Last known usage") && $0.contains(captured.ISO8601Format()) })
        }
    }

    @Test
    func `brief terminal summaries exclude historical warnings and resets`() throws {
        let now = ClaudeSwapRichUsageFixture.now
        let row = ClaudeSwapAccountRow(
            number: 1,
            email: "fixture@example.invalid",
            isActive: false,
            usageStatus: .unavailable,
            fiveHour: nil,
            sevenDay: nil,
            lastGoodUsage: .init(
                measurement: .init(
                    fiveHour: .init(usedPercent: 100, resetsAt: now.addingTimeInterval(900)),
                    sevenDay: nil),
                fetchedAt: now.addingTimeInterval(-3600)))
        let account = try #require(ClaudeSwapAccountProjection.accountSnapshots(
            from: .init(activeAccountNumber: nil, accounts: [row]), now: now).first)
        let card = CLICardsRenderer.makeClaudeSwapCard(
            account: account,
            renderOptions: .init(status: nil, useColor: false, resetStyle: .countdown, weeklyWorkDays: nil, now: now))
        #expect(card.metrics.first?.remainingPercent == 0)
        let brief = CLICardsBriefRenderer.makeRows(cards: [card])
        #expect(brief.first?.usedPercent == nil)
        #expect(brief.first?.resetAt == nil)
        #expect(brief.first?.resetLabel == nil)
        let rendered = CLICardsBriefRenderer.render(
            rows: brief, failures: [], terminalWidth: 100, useColor: false, now: now)
        #expect(!rendered.contains("Warnings"))
        #expect(!rendered.contains("Next reset:"))
        #expect(!rendered.contains("100%"))
        #expect(rendered.contains("Usage unavailable"))
        let live = CLICardModel(
            provider: .claude,
            title: "Claude",
            sourceLabel: "fixture",
            planBadge: nil,
            accountLine: "Live",
            infoLines: [],
            metrics: card.metrics,
            extraLines: [],
            statusLine: nil)
        let liveOutput = CLICardsBriefRenderer.render(
            rows: CLICardsBriefRenderer.makeRows(cards: [live]),
            failures: [],
            terminalWidth: 100,
            useColor: false,
            now: now)
        #expect(liveOutput.contains("Warnings"))
        #expect(liveOutput.contains("Next reset:"))
    }
}
