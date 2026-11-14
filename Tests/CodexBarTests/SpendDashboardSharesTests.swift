import CodexBarCore
import Testing
@testable import CodexBar

struct SpendDashboardSharesTests {
    private struct Row: Identifiable {
        let id: String
        let cost: Double?
        let tokens: Int?
    }

    @Test
    func `fully priced collections compare spend even when token shares differ`() {
        let rows = [Row(id: "a", cost: 10, tokens: 900), Row(id: "b", cost: 30, tokens: 100)]
        #expect(spendDashboardShares(rows, cost: \.cost, tokens: \.tokens) == ["a": 0.25, "b": 0.75])
    }

    @Test
    func `one unpriced row switches every bar to token shares`() {
        let rows = [Row(id: "a", cost: 10, tokens: 100), Row(id: "b", cost: nil, tokens: 900)]
        #expect(spendDashboardShares(rows, cost: \.cost, tokens: \.tokens) == ["a": 0.1, "b": 0.9])
    }

    @Test
    func `unpriced collections compare tokens`() {
        let rows = [Row(id: "a", cost: nil, tokens: 1), Row(id: "b", cost: nil, tokens: 3)]
        #expect(spendDashboardShares(rows, cost: \.cost, tokens: \.tokens) == ["a": 0.25, "b": 0.75])
    }

    @Test
    func `missing token counts do not establish a partial denominator`() {
        let rows = [Row(id: "a", cost: 10, tokens: nil), Row(id: "b", cost: nil, tokens: 900)]
        #expect(spendDashboardShares(rows, cost: \.cost, tokens: \.tokens).isEmpty)
    }

    @Test
    func `overflowing token totals hide shares without trapping`() {
        let rows = [Row(id: "a", cost: nil, tokens: .max), Row(id: "b", cost: nil, tokens: 1)]
        #expect(spendDashboardShares(rows, cost: \.cost, tokens: \.tokens).isEmpty)
    }

    @Test
    func `overflowing spend does not become a zero share or switch metrics`() {
        let rows = [
            Row(id: "a", cost: .greatestFiniteMagnitude, tokens: 1),
            Row(id: "b", cost: .greatestFiniteMagnitude, tokens: 3),
        ]
        #expect(spendDashboardShares(rows, cost: \.cost, tokens: \.tokens).isEmpty)
    }

    @Test
    func `zero totals and empty collections have no shares`() {
        for rows in [[], [Row(id: "a", cost: 0, tokens: 1)], [Row(id: "a", cost: nil, tokens: 0)]] {
            #expect(spendDashboardShares(rows, cost: \.cost, tokens: \.tokens).isEmpty)
        }
    }

    @Test
    func `largest valid token total remains finite`() {
        let rows = [Row(id: "a", cost: nil, tokens: Int.max - 1), Row(id: "b", cost: nil, tokens: 1)]
        let shares = spendDashboardShares(rows, cost: \.cost, tokens: \.tokens)
        #expect(shares.count == 2)
        #expect(shares.values.allSatisfy { $0.isFinite && (0...1).contains($0) })
        #expect(shares["b"] == 1 / Double(Int.max))
    }

    @Test
    func `complete provider totals compare spend`() {
        let breakdowns = [
            Self.breakdown(.codex, cost: 10, tokens: 900),
            Self.breakdown(.cursor, cost: 30, tokens: 100),
        ]
        #expect(spendDashboardProviderShares(breakdowns) == ["codex": 0.25, "cursor": 0.75])
    }

    @Test
    func `partial provider spend falls back to complete token shares`() {
        let breakdowns = [
            Self.breakdown(.codex, cost: 10, tokens: 900, hasPartialCost: true),
            Self.breakdown(.cursor, cost: 30, tokens: 100),
        ]
        #expect(spendDashboardProviderShares(breakdowns) == ["codex": 0.9, "cursor": 0.1])
    }

    @Test
    func `lower bound provider spend falls back to complete token shares`() {
        let breakdowns = [
            Self.breakdown(.codex, cost: 10, tokens: 900, costIsLowerBound: true),
            Self.breakdown(.cursor, cost: 30, tokens: 100),
        ]
        #expect(spendDashboardProviderShares(breakdowns) == ["codex": 0.9, "cursor": 0.1])
    }

    @Test
    func `partial provider tokens do not block complete spend shares`() {
        let breakdowns = [
            Self.breakdown(.codex, cost: 10, tokens: 900, hasPartialTokens: true),
            Self.breakdown(.cursor, cost: 30, tokens: 100),
        ]
        #expect(spendDashboardProviderShares(breakdowns) == ["codex": 0.25, "cursor": 0.75])
    }

    @Test
    func `incomplete spend and tokens hide provider shares`() {
        let partial = [
            Self.breakdown(.codex, cost: 10, tokens: 900, hasPartialCost: true, hasPartialTokens: true),
            Self.breakdown(.cursor, cost: 30, tokens: 100),
        ]
        let lowerBound = [
            Self.breakdown(.codex, cost: 10, tokens: 900, costIsLowerBound: true, tokensAreLowerBound: true),
            Self.breakdown(.cursor, cost: 30, tokens: 100),
        ]
        #expect(spendDashboardProviderShares(partial).isEmpty)
        #expect(spendDashboardProviderShares(lowerBound).isEmpty)
    }

    private static func breakdown(
        _ provider: UsageProvider,
        cost: Double?,
        tokens: Int?,
        hasPartialCost: Bool = false,
        hasPartialTokens: Bool = false,
        costIsLowerBound: Bool = false,
        tokensAreLowerBound: Bool = false) -> SpendProviderBreakdown
    {
        SpendProviderBreakdown(
            provider: provider,
            displayName: provider.rawValue,
            subscriptions: [SpendDashboardModel.ProviderRow(
                id: provider.rawValue,
                rank: 1,
                provider: provider,
                displayName: provider.rawValue,
                totalTokens: tokens,
                totalCost: cost,
                coveredDayCount: 1,
                costIsLowerBound: costIsLowerBound,
                tokensAreLowerBound: tokensAreLowerBound)],
            models: [],
            totalTokens: tokens,
            totalCost: cost,
            incompleteRequestCount: 0,
            hasPartialTokens: hasPartialTokens,
            hasPartialCost: hasPartialCost,
            hasPartialModelHistory: false,
            modelCount: 0)
    }
}
