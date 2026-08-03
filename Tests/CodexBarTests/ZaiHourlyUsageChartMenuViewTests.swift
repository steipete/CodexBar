import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct ZaiHourlyUsageChartMenuViewTests {
    @Test
    func `render state uses the selected dataset for bars legend colors and tooltip`() throws {
        let now = try #require(Calendar.current.date(from: DateComponents(
            year: 2026,
            month: 5,
            day: 14,
            hour: 12)))
        let hourly = ZaiModelUsageData(
            xTime: ["2026-05-14 08:00"],
            modelDataList: [
                ZaiModelDataItem(modelName: "hourly-model", tokensUsage: [50]),
            ])
        let daily = ZaiModelUsageData(
            xTime: ["2026-05-13", "2026-05-14"],
            modelDataList: [
                ZaiModelDataItem(modelName: "daily-model-a", tokensUsage: [100, 150]),
                ZaiModelDataItem(modelName: "daily-model-b", tokensUsage: [25, 75]),
            ])

        let dailyState = ZaiHourlyUsageChartMenuView.RenderState.make(
            modelUsage: hourly,
            dailyModelUsage: daily,
            selectedRange: .last7d,
            now: now)

        #expect(dailyState.modelNames == ["daily-model-a", "daily-model-b"])
        #expect(dailyState.bars.last?.segments.map(\.model) == ["daily-model-a", "daily-model-b"])
        #expect(dailyState.colorIndex(for: "daily-model-a", paletteCount: 6) == 0)
        #expect(dailyState.colorIndex(for: "daily-model-b", paletteCount: 6) == 1)
        #expect(try dailyState.tooltipTitle(for: #require(dailyState.bars.last)) == "05-14")

        let hourlyState = ZaiHourlyUsageChartMenuView.RenderState.make(
            modelUsage: hourly,
            dailyModelUsage: daily,
            selectedRange: .last24h,
            now: now)

        #expect(hourlyState.modelNames == ["hourly-model"])
        #expect(try hourlyState.tooltipTitle(for: #require(hourlyState.bars.last)) == "08:00")
    }
}
