import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ShareStatsPeriodTests {
    @MainActor
    @Test(arguments: [
        ("UTC", 9, 16),
        ("Pacific/Kiritimati", 9, 16),
        ("America/Los_Angeles", 9, 16),
        ("America/Los_Angeles", 3, 8),
        ("America/Los_Angeles", 11, 1),
        ("America/Santiago", 9, 6),
        ("UTC", 12, 31),
    ])
    func `share date names the last included reporting day`(dateCase: (String, Int, Int)) throws {
        let (zone, month, day) = dateCase
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: month,
            day: day,
            hour: 12)))
        let today = calendar.startOfDay(for: now)
        let dayInterval = try #require(calendar.dateInterval(of: .day, for: now))
        let dayKey = String(format: "2026-%02d-%02d", month, day)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 10,
            last30DaysCostUSD: 2,
            daily: [.init(
                date: dayKey,
                inputTokens: 5,
                outputTokens: 5,
                totalTokens: 10,
                costUSD: 2,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: now)
        let model = SpendDashboardModel.build(
            inputs: [.init(provider: .codex, displayName: "Codex", snapshot: snapshot)],
            requestedDays: 30,
            now: now,
            calendar: calendar)
        let group = try #require(model.groups.first)
        let payload = try #require(ShareStatsBuilder.make(model: model))

        // Chart width includes the next midnight; the human-facing date must not.
        #expect(group.chartDomain.upperBound == dayInterval.end)
        #expect(payload.periodEnd == today)
        #expect(payload.periodEnd < group.chartDomain.upperBound)
        #expect(payload.periodEndTimeZone == calendar.timeZone)
        #expect(payload.totalTokens == 10)
        #expect(payload.currencies.first?.estimatedCost == 2)
        let label = ShareStatsFormatting.dataThrough(payload)
        // Check the rendered civil date independently of the formatter under test.
        let dateReader = DateFormatter()
        dateReader.locale = .current
        dateReader.calendar = calendar
        dateReader.timeZone = calendar.timeZone
        dateReader.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
        let renderedDate = try #require(dateReader.date(from: label))
        let renderedDay = calendar.dateComponents([.year, .month, .day], from: renderedDate)
        #expect(renderedDay == DateComponents(year: 2026, month: month, day: day))
        #expect(ShareStatsFormatting.text(payload).contains("Data through \(label)"))

        if zone == "America/Los_Angeles", month == 9, day == 16,
           let directory = ProcessInfo.processInfo.environment["CODEXBAR_SHARE_STATS_SCREENSHOT_DIR"]
        {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            // Reproduce the old builder and formatter inputs through the same production renderer.
            let before = ShareStatsPayload(
                days: payload.days,
                periodEnd: group.chartDomain.upperBound,
                providers: payload.providers,
                topModels: payload.topModels,
                currencies: payload.currencies,
                totalTokens: payload.totalTokens,
                hasPartialTokens: payload.hasPartialTokens)
            #expect(ShareStatsFormatting.dataThrough(before)
                == ShareStatsFormatting.dataThrough(group.chartDomain.upperBound))
            #expect(ShareStatsFormatting.dataThrough(before) != ShareStatsFormatting.dataThrough(payload))
            for (name, snapshot) in [("before", before), ("after", payload)] {
                let png = try #require(ShareStatsRenderer.pngData(for: snapshot))
                try png.write(to: output.appendingPathComponent("share-period-date-\(name).png"), options: .atomic)
            }
        }
    }
}
