import Foundation
import Testing
@testable import CodexBar

struct SpendModelsPresentationTests {
    @Test
    func `model card range labels stay English and preserve compact order`() {
        #expect([7, 30, 365].map(spendModelsDayRangeText) == ["7d", "30d", "All"])
    }

    @Test
    func `model card date labels stay English`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 2)))

        #expect(SpendModelsEnglishFormatter.dayText(day) == "May 2")
    }

    @Test
    func `All axis keeps endpoints without crowded trailing labels`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 2)))
        let last = try #require(calendar.date(byAdding: .day, value: 78, to: start))
        let domainEnd = try #require(calendar.date(byAdding: .day, value: 79, to: start))

        let dates = SpendModelsAxisDates.make(
            selectedDays: 365,
            dataDays: [start, last],
            domain: start...domainEnd,
            calendar: calendar)

        #expect(dates.count == 6)
        #expect(dates.first == start)
        #expect(dates.last == last)
        for pair in zip(dates, dates.dropFirst()) {
            let gap = calendar.dateComponents([.day], from: pair.0, to: pair.1).day
            #expect((gap ?? 0) >= 8)
        }
    }

    @Test
    func `All axis replaces a near-duplicate trailing tick with the latest day`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        let last = try #require(calendar.date(byAdding: .day, value: 57, to: start))
        let domainEnd = try #require(calendar.date(byAdding: .day, value: 58, to: start))

        let dates = SpendModelsAxisDates.make(
            selectedDays: 365,
            dataDays: [start, last],
            domain: start...domainEnd,
            calendar: calendar)

        #expect(dates.count == 5)
        #expect(dates.last == last)
        let trailingGap = try #require(calendar.dateComponents(
            [.day],
            from: dates[dates.count - 2],
            to: dates[dates.count - 1]).day)
        #expect(trailingGap >= 8)
    }

    @Test
    func `every model remains a named chart series`() {
        let analysis = SpendDashboardModel.ModelAnalysis(
            rows: (1...6).map { index in
                Self.row(id: "model-\(index)", tokens: index * 10, cost: Double(index))
            },
            dailyValues: [
                .init(
                    modelID: "model-6",
                    modelName: "model-6",
                    day: Self.day,
                    totalTokens: 60,
                    inputTokens: 50,
                    outputTokens: 10,
                    estimatedCost: 6),
                .init(
                    modelID: "model-1",
                    modelName: "model-1",
                    day: Self.day,
                    totalTokens: 10,
                    inputTokens: 8,
                    outputTokens: 2,
                    estimatedCost: 1),
            ],
            trackedTokenTotal: 210,
            pricedCostTotal: 21,
            sourceCount: 1,
            tokenCoverage: .complete,
            costCoverage: .complete)
        let presentation = SpendModelsPresentation(analysis: analysis, metric: .tokens)

        #expect(presentation.rows.map(\.source.id) == [
            "model-6",
            "model-5",
            "model-4",
            "model-3",
            "model-2",
            "model-1",
        ])
        #expect(presentation.series.map(\.id) == [
            "model-6",
            "model-5",
            "model-4",
            "model-3",
            "model-2",
            "model-1",
        ])
        #expect(presentation.series.last?.name == "model-1")
        #expect(presentation.series.last?.value == 10)
        #expect(presentation.points.map(\.seriesID) == ["model-6", "model-1"])
        #expect(presentation.points.map(\.stackStart) == [0, 60])
        #expect(presentation.points.map(\.stackEnd) == [60, 70])
    }

    @Test
    func `token rows show in and out only when the split is complete`() {
        let complete = SpendModelsPresentation.Row(
            source: Self.row(
                id: "complete",
                tokens: 100,
                inputTokens: 80,
                outputTokens: 20,
                cost: nil,
                providers: ["Codex"]),
            rank: 1,
            value: 100,
            share: 1)
        let totalOnly = SpendModelsPresentation.Row(
            source: Self.row(
                id: "total",
                tokens: 96,
                cost: nil,
                providers: ["Kimi"]),
            rank: 2,
            value: 96,
            share: 1)

        #expect(spendModelsRowDetailText(complete) == "80 in · 20 out · Codex")
        #expect(spendModelsRowDetailText(totalOnly) == "96 · Kimi")
    }

    @Test
    func `spend metric ranks priced rows before rows with no price`() {
        let analysis = SpendDashboardModel.ModelAnalysis(
            rows: [
                Self.row(id: "unpriced", tokens: 1000, cost: nil),
                Self.row(id: "priced", tokens: 10, cost: 2),
            ],
            dailyValues: [],
            trackedTokenTotal: 1010,
            pricedCostTotal: 2,
            sourceCount: 1,
            tokenCoverage: .complete,
            costCoverage: .partial)
        let presentation = SpendModelsPresentation(analysis: analysis, metric: .estimatedSpend)

        #expect(presentation.rows.map(\.source.id) == ["priced", "unpriced"])
        #expect(presentation.rows.first?.share == 1)
        #expect(presentation.rows.last?.share == nil)
        #expect(presentation.coverage == .partial)
    }

    private static func row(
        id: String,
        tokens: Int?,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cost: Double?,
        providers: [String] = []) -> SpendDashboardModel.ModelAnalysisRow
    {
        SpendDashboardModel.ModelAnalysisRow(
            id: id,
            displayName: id,
            rawModelNames: [id],
            providers: [],
            providerNames: providers,
            contributions: [],
            totalTokens: tokens,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            estimatedCost: cost)
    }

    private static let day = Date(timeIntervalSince1970: 1_784_179_200)
}
