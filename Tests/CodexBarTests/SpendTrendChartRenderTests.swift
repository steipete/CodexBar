import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

/// Optional, offline rendering of the production chart, using only synthetic account history.
@MainActor
final class SpendTrendChartRenderTests: XCTestCase {
    func test_renderTrendFlow() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["CODEXBAR_SPEND_TREND_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_SPEND_TREND_PROOF_DIR for offline spend chart screenshots")
        }
        guard environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment["CODEXBAR_TEST_CODEX_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1"
        else { return XCTFail("Chart proof requires credential and session isolation") }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let inputs = try self.inputs()
        let calendar = Self.calendar
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 18)))
        let group = try XCTUnwrap(SpendDashboardModel.build(
            inputs: inputs,
            requestedDays: 14,
            now: now,
            calendar: calendar).groups.first)
        let longGroup = try XCTUnwrap(SpendDashboardModel.build(
            inputs: self.inputs(days: 120, multipleProviders: true),
            requestedDays: 120,
            now: now,
            calendar: calendar).groups.first)
        let yearGroup = try XCTUnwrap(SpendDashboardModel.build(
            inputs: self.inputs(days: 365, multipleProviders: true),
            requestedDays: 365,
            now: now,
            calendar: calendar).groups.first)
        let sparseGroup = try SpendTrendScopeTests.group()
        for (name, section, width, appearance, chartGroup, language, locale) in [
            (
                "02-daily-overview",
                SpendDashboardTrendSection.daily,
                760.0,
                NSAppearance.Name.aqua,
                group,
                "zh-Hans",
                "zh_CN"),
            ("03-hourly-day", .hourly, 760, .aqua, group, "zh-Hans", "zh_CN"),
            ("04-narrow-hourly", .hourly, 480, .aqua, group, "zh-Hans", "zh_CN"),
            ("05-dark-hourly", .hourly, 760, .darkAqua, group, "zh-Hans", "zh_CN"),
            ("06-dark-long-range", .daily, 760, .darkAqua, longGroup, "zh-Hans", "zh_CN"),
            ("07-narrow-long-range", .daily, 480, .darkAqua, longGroup, "zh-Hans", "zh_CN"),
            ("08-year-overview", .daily, 760, .aqua, yearGroup, "zh-Hans", "zh_CN"),
            ("09-component-icons", .daily, 760, .darkAqua, longGroup, "zh-Hans", "zh_CN"),
            ("10-english-hourly", .hourly, 760, .aqua, group, "en", "en_US"),
            ("11-german-narrow-hourly", .hourly, 480, .darkAqua, group, "de", "de_DE"),
            ("12-used-sources-only", .daily, 760, .aqua, sparseGroup, "zh-Hans", "zh_CN"),
            ("13-used-sources-narrow", .daily, 480, .aqua, sparseGroup, "zh-Hans", "zh_CN"),
            ("14-hourly-used-sources", .hourly, 760, .aqua, sparseGroup, "zh-Hans", "zh_CN"),
            ("15-used-sources-dark", .daily, 480, .darkAqua, sparseGroup, "zh-Hans", "zh_CN"),
        ] {
            try await CodexBarLocalizationOverride.$appLanguage.withValue(language) {
                let view = VStack(alignment: .leading, spacing: 16) {
                    SpendDashboardTrendPanel(
                        group: chartGroup,
                        selection: .constant(section),
                        onSelectDay: { _ in })
                    if name == "09-component-icons" {
                        SpendDashboardPanel { SpendProviderBreakdownRows(group: chartGroup) }
                    }
                }
                .padding(20).frame(width: width)
                .environment(\.locale, Locale(identifier: locale))
                .background(Color(nsColor: .windowBackgroundColor))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: appearance)
                let size = hosting.fittingSize
                XCTAssertGreaterThan(size.height, 300)
                let window = NSWindow(
                    contentRect: CGRect(origin: .zero, size: size),
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = hosting
                hosting.frame = CGRect(origin: .zero, size: size)
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("\(name).png"))
                window.close()
            }
        }
    }

    private func inputs(days: Int = 14, multipleProviders: Bool = false) throws -> [SpendDashboardModel.ProviderInput] {
        let calendar = Self.calendar
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 18)))
        let today = calendar.startOfDay(for: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let accounts: [(String, UsageProvider, String)] = multipleProviders
            ? [
                ("account-a", .codex, "Codex · #1"),
                ("account-b", .codex, "Codex"),
                ("cursor", .cursor, "Cursor"),
                ("antigravity", .antigravity, "Antigravity"),
            ]
            : [("account-a", .codex, "Codex · #1"), ("account-b", .codex, "Codex")]
        return try accounts.enumerated().map { source, account in
            var hourly: [CostUsageHourlyEntry] = []
            var daily: [CostUsageDailyReport.Entry] = []
            for offset in -(days - 2)...0 {
                let day = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: today))
                if source < 2 && offset < -12 { continue }
                if source >= 2 && offset < -12 && abs(offset) % (source == 2 ? 11 : 23) != 0 { continue }
                var total = 0.0
                for hour in [9, 10, 14, 17, 21] where offset < 0 || hour <= 18 {
                    let cost = offset == -5 && hour == 14 ? 32.0 + Double(source) * 15
                        : Double((abs(offset) + hour + source * 3) % 11 + 1) * 0.65
                    let recorded = source == 2 ? cost * 1.4 : source == 3 ? cost * 0.4 : cost
                    total += recorded
                    if source >= 2 { continue }
                    hourly.append(CostUsageHourlyEntry(
                        hour: day.addingTimeInterval(Double(hour) * 3600), totalTokens: 1000, costUSD: cost))
                }
                daily.append(CostUsageDailyReport.Entry(
                    date: formatter.string(from: day),
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 5000,
                    costUSD: total,
                    modelsUsed: nil,
                    modelBreakdowns: nil))
            }
            let snapshot = CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: 65000,
                last30DaysCostUSD: daily.compactMap(\.costUSD).reduce(0, +),
                historyDays: days,
                costProvenance: .listPriceEstimate,
                daily: daily,
                hourly: hourly,
                updatedAt: now)
            return SpendDashboardModel.ProviderInput(
                id: account.0,
                provider: account.1,
                displayName: account.2,
                snapshot: snapshot)
        }
    }

    fileprivate static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
        return calendar
    }
}
