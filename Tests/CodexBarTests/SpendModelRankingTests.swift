import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SpendModelRankingTests {
    private static func row(
        _ name: String,
        provider: UsageProvider = .claude,
        cost: Double?,
        tokens: Int?) -> SpendDashboardModel.ModelRow
    {
        SpendDashboardModel.ModelRow(
            rank: 0,
            provider: provider.instanceID,
            providerName: provider == .claude ? "Claude" : "Codex",
            modelName: name,
            totalTokens: tokens,
            totalCost: cost)
    }

    @Test
    func `models section appears second only when models exist`() {
        #expect(spendDashboardAvailableDetailSections(hasProjects: true, hasSessions: false, hasModels: true)
            == [.providers, .models, .projects])
        #expect(spendDashboardAvailableDetailSections(hasProjects: true, hasSessions: false, hasModels: false)
            == [.providers, .projects])
    }

    @Test
    func `fully priced models rank across providers by spend share of the whole group`() throws {
        let ranking = try #require(SpendModelRanking.make([
            Self.row("claude-sonnet", cost: 30, tokens: 900),
            Self.row("gpt-codex", provider: .codex, cost: 60, tokens: 100),
            Self.row("claude-haiku", cost: 10, tokens: 5000),
        ]))

        #expect(ranking.basis == .cost)
        #expect(ranking.rows.map(\.model.modelName) == ["gpt-codex", "claude-sonnet", "claude-haiku"])
        #expect(ranking.rows.map(\.share) == [0.6, 0.3, 0.1])
    }

    @Test
    func `one unpriced model switches the whole ranking to tokens`() throws {
        let ranking = try #require(SpendModelRanking.make([
            Self.row("priced", cost: 50, tokens: 100),
            Self.row("unpriced", cost: nil, tokens: 300),
        ]))

        #expect(ranking.basis == .tokens)
        #expect(ranking.rows.map(\.model.modelName) == ["unpriced", "priced"])
        #expect(ranking.rows.map(\.share) == [0.75, 0.25])
    }

    @Test
    func `token shares never compare different providers' tokenizers`() throws {
        let ranking = try #require(SpendModelRanking.make([
            Self.row("claude-unpriced", cost: nil, tokens: 100),
            Self.row("gpt-codex", provider: .codex, cost: 50, tokens: 900),
        ]))

        #expect(ranking.basis == nil)
        #expect(ranking.rows.map(\.model.modelName) == ["claude-unpriced", "gpt-codex"])
        #expect(ranking.rows.allSatisfy { $0.share == nil })
    }

    @Test
    func `rows without a comparable value stay listed without shares`() throws {
        #expect(SpendModelRanking.make([]) == nil)

        let mixed = try #require(SpendModelRanking.make([
            Self.row("priced", cost: 5, tokens: nil),
            Self.row("unknown", cost: nil, tokens: nil),
        ]))
        #expect(mixed.basis == nil)
        #expect(mixed.rows.map(\.model.modelName) == ["priced", "unknown"])
        #expect(mixed.rows.allSatisfy { $0.share == nil })

        let idle = try #require(SpendModelRanking.make([Self.row("idle", cost: 0, tokens: 0)]))
        #expect(idle.basis == nil)
        #expect(idle.rows.count == 1)
    }

    @Test
    func `shares divide by every model even when the list is collapsed`() throws {
        let models = (1...8).map { Self.row("model-\($0)", cost: 10, tokens: 10) }
        let ranking = try #require(SpendModelRanking.make(models))

        #expect(SpendModelRanking.visibleRowCount(total: ranking.rows.count, showsAll: false) == 5)
        #expect(ranking.rows.prefix(5).allSatisfy { $0.share == 0.125 })
    }

    @Test
    func `oversized token counts rank without overflowing`() throws {
        let ranking = try #require(SpendModelRanking.make([
            Self.row("huge", cost: nil, tokens: Int.max),
            Self.row("small", cost: nil, tokens: 1),
        ]))

        #expect(ranking.basis == .tokens)
        #expect(ranking.rows.first?.model.totalTokens == Int.max)
        #expect(ranking.rows.allSatisfy { row in
            guard let share = row.share else { return false }
            return share.isFinite && share >= 0 && share <= 1
        })
    }

    @Test
    func `short lists show every row without an expand control`() {
        #expect(SpendModelRanking.visibleRowCount(total: 6, showsAll: false) == 6)
        #expect(SpendModelRanking.visibleRowCount(total: 7, showsAll: false) == 5)
        #expect(SpendModelRanking.visibleRowCount(total: 7, showsAll: true) == 7)
    }

    @Test
    func `share text keeps small shares visible`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            #expect(spendDashboardShareText(0.6) == "60%")
            #expect(spendDashboardShareText(0.004) == "0.4%")
        }
    }
}
