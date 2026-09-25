import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

/// Opt-in synthetic proof; never opens Settings or reads account configuration.
@MainActor
final class SpendDashboardLongRangeRenderTests: XCTestCase {
    func test_longRangeStartsWithBoundedLedger() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_LONG_RANGE_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_LONG_RANGE_PROOF_DIR to render the synthetic long-range ledger.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 12)))
        let dayFormat = DateFormatter()
        dayFormat.calendar = calendar
        dayFormat.timeZone = calendar.timeZone
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.dateFormat = "yyyy-MM-dd"
        let daily = try (0..<365).map { offset in
            let date = try XCTUnwrap(calendar.date(byAdding: .day, value: -offset, to: now))
            return CostUsageDailyReport.Entry(
                date: dayFormat.string(from: date),
                inputTokens: 800,
                outputTokens: 200,
                totalTokens: 1000,
                requestCount: 1,
                costUSD: 1,
                modelsUsed: ["fixture-model"],
                modelBreakdowns: [.init(modelName: "fixture-model", costUSD: 1, totalTokens: 1000)])
        }
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 1000,
            sessionCostUSD: 1,
            last30DaysTokens: 365_000,
            last30DaysCostUSD: 365,
            historyDays: 365,
            historyCoverageIsEstablished: true,
            daily: daily,
            updatedAt: now)
        let input = SpendDashboardModel.ProviderInput(provider: .codex, displayName: "Codex", snapshot: snapshot)
        var buildTimes: [Double] = []
        var model = SpendDashboardModel(requestedDays: 365, groups: [])
        for _ in 0..<11 {
            let start = ContinuousClock.now
            model = SpendDashboardModel.build(
                inputs: [input], reportingPeriod: .allTime, now: now, calendar: calendar)
            buildTimes.append(Self.milliseconds(start.duration(to: .now)))
        }
        let group = try XCTUnwrap(model.groups.first)
        XCTAssertEqual(group.dailySummaries.count, 365)
        XCTAssertEqual(group.totalCost, 365)
        XCTAssertEqual(group.totalTokens, 365_000)
        XCTAssertEqual(group.dailySummaries.compactMap(\.requestCount).reduce(0, +), 365)
        print("LONG_RANGE model_build_median_ms=\(buildTimes.dropFirst().sorted()[5]) days=365 cost=365 tokens=365000")

        var layoutTimes: [Double] = []
        for iteration in 0..<4 {
            let start = ContinuousClock.now
            let view = SpendDashboardCurrencySection(group: group, requestedDays: model.requestedDays)
                .padding(24)
                .frame(width: 760)
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                .background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: view)
            hosting.appearance = NSAppearance(named: .aqua)
            let size = hosting.fittingSize
            hosting.frame = CGRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            layoutTimes.append(Self.milliseconds(start.duration(to: .now)))
            print("LONG_RANGE layout_ms=\(layoutTimes.last!) height=\(size.height) iteration=\(iteration)")
            if iteration == 0 {
                // Capture the first screenful at a fixed size so before/after images remain comparable.
                let height = min(size.height, 2000)
                let rect = CGRect(
                    x: 0, y: hosting.isFlipped ? 0 : size.height - height, width: size.width, height: height)
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: rect))
                hosting.cacheDisplay(in: rect, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("long-range.png"))
            }
            XCTAssertLessThan(size.height, 3000, "The initial ledger should not mount all 365 days.")
        }
        print("LONG_RANGE layout_median_ms=\(layoutTimes.dropFirst().sorted()[1])")
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
