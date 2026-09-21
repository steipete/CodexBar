import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ShareStatsCompletenessTests {
    @Test(arguments: ["complete", "unpriced", "incomplete", "missing-models"])
    @MainActor
    func `USD model rankings isolate incomplete providers`(_ scenario: String) throws {
        let model = Self.dashboard(scenario: scenario)
        let group = try #require(model.groups.first)
        let payload = try #require(ShareStatsBuilder.make(model: model))
        let isPartial = scenario != "complete"

        #expect(model.groups.count == 1)
        #expect(group.currencyCode == "USD")
        #expect(group.providers.count == 3)
        #expect(group.incompleteModelProviders == (isPartial ? [.antigravity] : []))
        #expect(payload.hasPartialModels == isPartial)
        #expect(payload.modelRankingDetail == (isPartial ? "PARTIAL" : "BY USAGE"))

        if ["unpriced", "complete"].contains(scenario),
           let directory = ProcessInfo.processInfo.environment["CODEXBAR_SHARE_STATS_SCREENSHOT_DIR"]
        {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let name = scenario == "unpriced" ? "share-model-completeness" : "share-model-complete"
            let png = try #require(ShareStatsRenderer.pngData(for: payload))
            try png.write(to: output.appendingPathComponent("\(name).png"), options: .atomic)
            try ShareStatsFormatting.text(payload).write(
                to: output.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        }

        #expect(payload.topModels.map(\.provider) == (isPartial ? [.codex, .claude] : [.codex, .claude, .antigravity]))
        #expect(payload.topModels.map(\.modelName) == (isPartial ? ["GPT", "Claude"] : ["GPT", "Claude", "Gemini"]))
        #expect(payload.topModels.first?.totalTokens == 300)
        #expect(payload.topModels.first?.estimatedCost == 3)
        let text = ShareStatsFormatting.text(payload)
        #expect(text.contains(isPartial ? "Top models (partial):" : "Top models:"))
        #expect(text.contains("Top models (partial):") == isPartial)
        #expect(text.contains("GPT (Codex): 300 tokens"))
        #expect(text.contains("Claude (Claude): 200 tokens"))
        #expect(text.contains("Gemini (Antigravity)") == !isPartial)
    }

    @Test
    func `one incomplete account excludes only its provider`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let model = SpendDashboardModel.build(
            inputs: [
                Self.input(provider: .codex, name: "Codex A", model: "gpt-4o", tokens: 300, cost: 3),
                Self.input(provider: .codex, name: "Codex B", model: "gpt-4o", tokens: 100, cost: 1, incomplete: 1),
                Self.input(provider: .claude, name: "Claude", model: "claude-sonnet-4", tokens: 200, cost: 2),
            ],
            requestedDays: 7,
            now: Self.now,
            calendar: calendar)
        let payload = try #require(ShareStatsBuilder.make(model: model))

        #expect(payload.providers.count == 3)
        #expect(payload.hasPartialModels)
        #expect(payload.topModels.map(\.provider) == [.claude])
        #expect(payload.topModels.first?.totalTokens == 200)
    }

    @Test(arguments: [0, -1])
    func `selected day models are not advertised as the full reporting window`(dayOffset: Int) throws {
        let payload = try #require(ShareStatsBuilder.make(model: Self.dashboard(
            scenario: "complete",
            selectedDay: Self.now.addingTimeInterval(Double(dayOffset) * 86400))))

        #expect(payload.days == 7)
        #expect(payload.hasPartialModels)
        #expect(payload.modelRankingDetail == "PARTIAL")
        #expect(payload.topModels.isEmpty)
        #expect(!ShareStatsFormatting.text(payload).contains("Top models"))
    }

    @Test
    func `an idle full window does not claim a partial ranking`() throws {
        let payload = try #require(ShareStatsBuilder.make(model: Self.dashboard(
            scenario: "idle",
            selectedDay: Self.now.addingTimeInterval(-86400))))

        #expect(payload.totalTokens == 0)
        #expect(payload.currencies.first?.estimatedCost == 0)
        #expect(payload.topModels.isEmpty)
        #expect(!payload.hasPartialModels)
        #expect(payload.modelRankingDetail == "BY USAGE")
    }

    @Test(arguments: ["unknown-cost", "unknown-tokens", "unknown"])
    func `unavailable full window totals are not idle`(_ scenario: String) throws {
        let payload = try #require(ShareStatsBuilder.make(model: Self.dashboard(
            scenario: scenario,
            selectedDay: Self.now.addingTimeInterval(-86400))))
        let unavailable = try #require(payload.providers.first { $0.provider == .antigravity })

        #expect(unavailable.totalTokens == (scenario == "unknown-cost" ? 0 : nil))
        #expect(unavailable.estimatedCost == (scenario == "unknown-tokens" ? 0 : nil))
        #expect(payload.hasPartialModels)
        #expect(payload.modelRankingDetail == "PARTIAL")
    }

    @Test(arguments: ["missing-cost", "token-overflow", "cost-overflow", "both-overflow"])
    func `family aggregation preserves unavailable amounts`(_ scenario: String) throws {
        let tokenOverflow = scenario == "token-overflow" || scenario == "both-overflow"
        let costOverflow = scenario == "cost-overflow" || scenario == "both-overflow"
        let group = try #require(Self.dashboard(scenario: "complete").groups.first)
        let models: [SpendDashboardModel.ModelRow] = [
            .init(
                rank: 1,
                provider: .codex,
                providerName: "Codex",
                modelName: "gpt-4o",
                totalTokens: tokenOverflow ? Int.max : 10,
                totalCost: costOverflow ? Double.greatestFiniteMagnitude : 1),
            .init(
                rank: 2,
                provider: .codex,
                providerName: "Codex",
                modelName: "gpt-4o-mini",
                totalTokens: 20,
                totalCost: scenario == "missing-cost" ? nil : costOverflow ? Double.greatestFiniteMagnitude : 2),
            .init(
                rank: 3,
                provider: .codex,
                providerName: "Codex",
                modelName: "gpt-fixture",
                totalTokens: 1,
                totalCost: 1),
        ]
        let payload = try #require(ShareStatsBuilder.make(model: SpendDashboardModel(requestedDays: 7, groups: [
            .init(
                currencyCode: "USD",
                providers: group.providers,
                models: models,
                dailyPoints: [],
                totalTokens: group.totalTokens,
                totalCost: group.totalCost,
                coveredDayCount: 7,
                chartDomain: group.chartDomain,
                modelHistoryCompleteness: .complete),
        ])))

        if scenario == "both-overflow" {
            #expect(payload.topModels.isEmpty)
        } else {
            let family = try #require(payload.topModels.first)
            #expect(payload.topModels.count == 1)
            #expect(family.totalTokens == (tokenOverflow ? nil : 31))
            #expect(family.estimatedCost == (costOverflow || scenario == "missing-cost" ? nil : 4))
        }
    }

    private static func dashboard(scenario: String, selectedDay: Date? = nil) -> SpendDashboardModel {
        let zeroBaseline = scenario == "idle" || scenario.hasPrefix("unknown")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return SpendDashboardModel.build(
            inputs: [
                Self.input(
                    provider: .codex,
                    name: "Codex",
                    model: "gpt-4o",
                    tokens: zeroBaseline ? 0 : 300,
                    cost: zeroBaseline ? 0 : 3,
                    hasModels: !zeroBaseline),
                Self.input(
                    provider: .claude,
                    name: "Claude",
                    model: "claude-sonnet-4",
                    tokens: zeroBaseline ? 0 : 200,
                    cost: zeroBaseline ? 0 : 2,
                    hasModels: !zeroBaseline),
                Self.input(
                    provider: .antigravity,
                    name: "Antigravity",
                    model: "gemini-2.5-flash",
                    tokens: ["unknown", "unknown-tokens"].contains(scenario) ? nil : zeroBaseline ? 0 : 100,
                    cost: ["unknown", "unknown-cost", "unpriced"].contains(scenario) ? nil : zeroBaseline ? 0 : 1,
                    incomplete: scenario == "incomplete" ? 1 : 0,
                    hasModels: !zeroBaseline && scenario != "missing-models"),
            ],
            requestedDays: 7,
            now: Self.now,
            calendar: calendar,
            selectedDay: selectedDay)
    }

    private static func input(
        provider: UsageProvider,
        name: String,
        model: String,
        tokens: Int?,
        cost: Double?,
        incomplete: Int = 0,
        hasModels: Bool = true) -> SpendDashboardModel.ProviderInput
    {
        .init(id: name, provider: provider, displayName: name, snapshot: CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            daily: [.init(
                date: "2026-07-16",
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: tokens,
                costUSD: cost,
                modelsUsed: nil,
                modelBreakdowns: hasModels ? [.init(
                    modelName: model,
                    costUSD: cost,
                    totalTokens: tokens,
                    incompleteRequestCount: incomplete)] : nil)],
            updatedAt: self.now))
    }

    private static let now = Date(timeIntervalSince1970: 1_784_179_200)
}
