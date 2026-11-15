import CodexBarCore
import Testing
@testable import CodexBar

struct SpendDashboardSharesTests {
    private struct Row: Identifiable {
        let id: String
        let cost: Double?
        let tokens: Int?
        var provider: UsageProvider = .codex
    }

    private static func shares(_ rows: [Row]) -> SpendDashboardShares<String>? {
        spendDashboardShares(rows, cost: \.cost, tokens: \.tokens, provider: \.provider)
    }

    @Test
    func `fully priced collections compare spend even when token shares differ`() {
        let rows = [Row(id: "a", cost: 10, tokens: 900), Row(id: "b", cost: 30, tokens: 100)]
        #expect(Self.shares(rows) == SpendDashboardShares(basis: .cost, values: ["a": 0.25, "b": 0.75]))
    }

    @Test
    func `one unpriced row switches every bar to token shares and says so`() {
        let rows = [Row(id: "a", cost: 10, tokens: 100), Row(id: "b", cost: nil, tokens: 900)]
        let shares = Self.shares(rows)
        #expect(shares == SpendDashboardShares(basis: .tokens, values: ["a": 0.1, "b": 0.9]))
        #expect(shares?.basisTitle == L("Tracked tokens"))
    }

    @Test
    func `same rows report which metric their bars measure`() {
        // Spend 1/9 and tokens 900/100 reverse each other; the basis tells them apart.
        let priced = [Row(id: "a", cost: 1, tokens: 900), Row(id: "b", cost: 9, tokens: 100)]
        let unpriced = [Row(id: "a", cost: nil, tokens: 900), Row(id: "b", cost: 9, tokens: 100)]
        #expect(Self.shares(priced)?.basisTitle == L("Estimated spend"))
        #expect(Self.shares(unpriced)?.basisTitle == L("Tracked tokens"))
    }

    @Test
    func `token shares never compare different providers`() {
        let rows = [
            Row(id: "a", cost: nil, tokens: 100, provider: .claude),
            Row(id: "b", cost: 5, tokens: 900, provider: .codex),
        ]
        #expect(Self.shares(rows) == nil)
    }

    @Test
    func `complete spend still compares different providers`() {
        let rows = [
            Row(id: "a", cost: 1, tokens: 100, provider: .claude),
            Row(id: "b", cost: 3, tokens: 900, provider: .codex),
        ]
        #expect(Self.shares(rows) == SpendDashboardShares(basis: .cost, values: ["a": 0.25, "b": 0.75]))
    }

    @Test
    func `unpriced collections compare tokens`() {
        let rows = [Row(id: "a", cost: nil, tokens: 1), Row(id: "b", cost: nil, tokens: 3)]
        #expect(Self.shares(rows) == SpendDashboardShares(basis: .tokens, values: ["a": 0.25, "b": 0.75]))
    }

    @Test
    func `missing token counts do not establish a partial denominator`() {
        let rows = [Row(id: "a", cost: 10, tokens: nil), Row(id: "b", cost: nil, tokens: 900)]
        #expect(Self.shares(rows) == nil)
    }

    @Test
    func `overflowing token totals hide shares without trapping`() {
        let rows = [Row(id: "a", cost: nil, tokens: .max), Row(id: "b", cost: nil, tokens: 1)]
        #expect(Self.shares(rows) == nil)
    }

    @Test
    func `overflowing spend does not become a zero share or switch metrics`() {
        let rows = [
            Row(id: "a", cost: .greatestFiniteMagnitude, tokens: 1),
            Row(id: "b", cost: .greatestFiniteMagnitude, tokens: 3),
        ]
        #expect(Self.shares(rows) == nil)
    }

    @Test
    func `zero totals and empty collections have no shares`() {
        for rows in [[], [Row(id: "a", cost: 0, tokens: 1)], [Row(id: "a", cost: nil, tokens: 0)]] {
            #expect(Self.shares(rows) == nil)
        }
    }

    @Test
    func `largest valid token total remains finite`() {
        let rows = [Row(id: "a", cost: nil, tokens: Int.max - 1), Row(id: "b", cost: nil, tokens: 1)]
        let shares = Self.shares(rows)?.values ?? [:]
        #expect(shares.count == 2)
        #expect(shares.values.allSatisfy { $0.isFinite && (0...1).contains($0) })
        #expect(shares["b"] == 1 / Double(Int.max))
    }

    @Test
    func `lower bound project spend falls back to same provider tokens`() {
        let rows = [
            Self.project("a", cost: 4, tokens: 900, costIsLowerBound: true),
            Self.project("b", cost: 6, tokens: 100),
        ]
        let shares = spendDashboardProjectShares(rows)
        #expect(shares?.basis == .tokens)
        #expect(shares?.values == [rows[0].id: 0.9, rows[1].id: 0.1])
    }

    @Test
    func `lower bound project spend and tokens hide shares`() {
        let rows = [
            Self.project("a", cost: 4, tokens: 900, costIsLowerBound: true, tokensAreLowerBound: true),
            Self.project("b", cost: 6, tokens: 100),
        ]
        #expect(spendDashboardProjectShares(rows) == nil)
    }

    @Test
    func `mixed provider projects without complete spend hide shares`() {
        let rows = [
            Self.project("a", cost: nil, tokens: 100, provider: .claude),
            Self.project("b", cost: 6, tokens: 900),
        ]
        #expect(spendDashboardProjectShares(rows) == nil)
    }

    @Test
    func `complete provider totals compare spend`() {
        let breakdowns = [
            Self.breakdown(.codex, cost: 10, tokens: 900),
            Self.breakdown(.cursor, cost: 30, tokens: 100),
        ]
        #expect(spendDashboardProviderShares(breakdowns)?.values == ["codex": 0.25, "cursor": 0.75])
    }

    @Test
    func `partial or lower bound provider spend hides shares across tokenizers`() {
        for breakdowns in [
            [
                Self.breakdown(.codex, cost: 10, tokens: 900, hasPartialCost: true),
                Self.breakdown(.cursor, cost: 30, tokens: 100),
            ],
            [
                Self.breakdown(.codex, cost: 10, tokens: 900, costIsLowerBound: true),
                Self.breakdown(.cursor, cost: 30, tokens: 100),
            ],
        ] {
            #expect(spendDashboardProviderShares(breakdowns) == nil)
        }
    }

    @Test
    func `partial provider tokens do not block complete spend shares`() {
        let breakdowns = [
            Self.breakdown(.codex, cost: 10, tokens: 900, hasPartialTokens: true),
            Self.breakdown(.cursor, cost: 30, tokens: 100),
        ]
        #expect(spendDashboardProviderShares(breakdowns)?.values == ["codex": 0.25, "cursor": 0.75])
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
        #expect(spendDashboardProviderShares(partial) == nil)
        #expect(spendDashboardProviderShares(lowerBound) == nil)
    }

    private static func project(
        _ name: String,
        cost: Double?,
        tokens: Int?,
        provider: UsageProvider = .codex,
        costIsLowerBound: Bool = false,
        tokensAreLowerBound: Bool = false) -> SpendDashboardModel.ProjectRow
    {
        SpendDashboardModel.ProjectRow(
            rank: 1,
            provider: provider,
            providerName: provider.rawValue,
            sourceID: provider.rawValue,
            projectName: name,
            path: "/fixtures/\(name)",
            totalTokens: tokens,
            totalCost: cost,
            costIsLowerBound: costIsLowerBound,
            tokensAreLowerBound: tokensAreLowerBound)
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
