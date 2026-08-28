import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

/// Developer tool, skipped by default: renders the Usage & Spend currency section for PR proof.
///
/// Run with:
///   CODEXBAR_SPEND_PROOF_DIR=.github/pr-proof swift test --filter SpendDashboardScreenshotRenderTests
@MainActor
final class SpendDashboardScreenshotRenderTests: XCTestCase {
    func test_renderUsageSpendRangeScreenshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_SPEND_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_SPEND_PROOF_DIR to render Usage & Spend proof screenshots.")
        }
        let directory = URL(
            fileURLWithPath: NSString(string: dir).expandingTildeInPath,
            isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let calendar = Self.gmtCalendar
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 17, hour: 12)))
        let recentDay = "2026-08-17"
        let oldDay = "2026-07-12"
        let claude = SpendDashboardModel.ProviderInput(
            provider: .claude,
            displayName: "Claude",
            snapshot: Self.snapshot(
                entries: [
                    Self.entry(day: oldDay, cost: 1.2, tokens: 40, model: "MiniMax-M3"),
                    Self.entry(day: recentDay, cost: 0.4, tokens: 10, model: "deepseek-v4-flash"),
                ],
                historyDays: SpendDashboardSource.scanDays,
                now: now))
        let cursor = SpendDashboardModel.ProviderInput(
            provider: .cursor,
            displayName: "Cursor",
            snapshot: Self.snapshot(
                entries: [
                    Self.entry(day: recentDay, cost: nil, tokens: 8, model: "deepseek-v4-flash"),
                ],
                historyDays: SpendDashboardSource.scanDays,
                now: now))

        let thirty = SpendDashboardModel.build(
            inputs: [claude, cursor],
            requestedDays: 30,
            now: now,
            calendar: calendar)
        let allTime = SpendDashboardModel.build(
            inputs: [claude, cursor],
            requestedDays: SpendDashboardSource.scanDays,
            now: now,
            calendar: calendar)
        let thirtyGroup = try XCTUnwrap(thirty.groups.first)
        let allGroup = try XCTUnwrap(allTime.groups.first)
        XCTAssertFalse(thirtyGroup.models.contains { $0.modelName == "MiniMax-M3" })
        XCTAssertTrue(allGroup.models.contains { $0.modelName == "MiniMax-M3" })

        let hourlyHours = [9, 10, 11, 14, 16].map { hour -> (Date, Double) in
            let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 17, hour: hour)) ?? now
            let cost = [9: 0.4, 10: 1.1, 11: 0.7, 14: 0.9, 16: 0.3][hour] ?? 0.5
            return (date, cost)
        }
        let openCodex = SpendDashboardModel.ProviderInput(
            id: SpendDashboardModel.openCodexSourceID,
            provider: .codex,
            displayName: "OpenCodex",
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: 80,
                sessionCostUSD: 3.4,
                last30DaysTokens: 80,
                last30DaysCostUSD: 3.4,
                historyDays: 7,
                costProvenance: .listPriceEstimate,
                daily: [Self.entry(day: recentDay, cost: 3.4, tokens: 80, model: "gpt-5.4")],
                hourly: hourlyHours.map { CostUsageHourlyEntry(hour: $0.0, totalTokens: 16, costUSD: $0.1) },
                updatedAt: now),
            sourceKind: .openCodex)
        let nativeCodex = SpendDashboardModel.ProviderInput(
            id: "codex",
            provider: .codex,
            displayName: "Codex",
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: 40,
                sessionCostUSD: 2.1,
                last30DaysTokens: 40,
                last30DaysCostUSD: 2.1,
                historyDays: 7,
                costProvenance: .listPriceEstimate,
                daily: [Self.entry(day: recentDay, cost: 2.1, tokens: 40, model: "gpt-5.4")],
                sessions: [
                    CostUsageSessionBreakdown(
                        sessionID: "native-1",
                        lastActivity: now,
                        inputTokens: 30,
                        cachedInputTokens: nil,
                        outputTokens: 10,
                        totalTokens: 40,
                        requestCount: 1,
                        costUSD: 2.1,
                        modelBreakdowns: []),
                ],
                updatedAt: now))
        let hourly = SpendDashboardModel.build(
            inputs: [openCodex, nativeCodex],
            requestedDays: 7,
            now: now,
            calendar: calendar)
        let selectedDay = calendar.startOfDay(for: now)
        let selected = SpendDashboardModel.build(
            inputs: [openCodex, nativeCodex],
            requestedDays: 7,
            now: now,
            calendar: calendar,
            selectedDay: selectedDay)
        let hourlyGroup = try XCTUnwrap(hourly.groups.first)
        let selectedGroup = try XCTUnwrap(selected.groups.first)
        XCTAssertFalse(hourlyGroup.hourlyPoints.isEmpty)
        XCTAssertEqual(Set(hourlyGroup.hourlyPoints.map(\.sourceID)), [SpendDashboardModel.openCodexSourceID])
        XCTAssertEqual(selectedGroup.hourlyChartDomain?.lowerBound, selectedDay)

        let renders: [(String, AnyView)] = [
            ("usage-spend-30d", AnyView(Self.chrome(selectedDays: 30, group: thirtyGroup))),
            ("usage-spend-all", AnyView(Self.chrome(selectedDays: SpendDashboardSource.scanDays, group: allGroup))),
            ("usage-spend-export-actions", AnyView(Self.exportActionsChrome())),
            ("usage-spend-hourly", AnyView(Self.chrome(selectedDays: 7, group: hourlyGroup))),
            ("usage-spend-hourly-selected-day", AnyView(Self.chrome(selectedDays: 7, group: selectedGroup))),
            (
                "overview-spend-summary",
                AnyView(
                    OverviewSpendSummaryCardView(
                        summary: OverviewSpendSummary(model: thirty, providerCount: 2),
                        days: 30,
                        width: 320)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .windowBackgroundColor)))),
        ]
        for (name, view) in renders {
            let data = try XCTUnwrap(Self.pngData(for: view), "render failed for \(name)")
            let url = directory.appendingPathComponent("\(name).png")
            try data.write(to: url, options: .atomic)
            print("Wrote \(url.path)")
        }

        if let sharePayload = ShareStatsBuilder.make(model: allTime) {
            let shareData = try XCTUnwrap(ShareStatsRenderer.pngData(for: sharePayload))
            try shareData.write(
                to: directory.appendingPathComponent("share-stats-all-partial.png"),
                options: .atomic)
        }
    }

    private static func chrome(selectedDays: Int, group: SpendDashboardModel.CurrencyGroup) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Usage & Spend")
                        .font(.title2.weight(.semibold))
                    Text("Local estimated cost history across supported providers.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 0) {
                    ForEach([7, 30, SpendDashboardSource.scanDays], id: \.self) { days in
                        Text(days >= SpendDashboardSource.scanDays ? "All" : "\(days)d")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(days == selectedDays ? Color.primary.opacity(0.12) : Color.clear)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
                }
            }
            SpendDashboardCurrencySection(group: group, requestedDays: selectedDays)
        }
        .padding(24)
        .frame(width: 760)
        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
        .environment(\.timeZone, group.timeZone)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private static func exportActionsChrome() -> some View {
        HStack {
            Button {} label: {
                Label("Copy JSON", systemImage: "doc.on.doc")
            }
            Button {} label: {
                Label("Export JSON", systemImage: "square.and.arrow.down")
            }
            Spacer()
            Button {} label: {
                Label("Share Stats…", systemImage: "square.and.arrow.up")
            }
        }
        .padding(24)
        .frame(width: 760)
        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private static func pngData(for view: AnyView) -> Data? {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .aqua)
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return nil }
        hosting.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        return representation.representation(using: .png, properties: [:])
    }

    private static func snapshot(
        entries: [CostUsageDailyReport.Entry],
        historyDays: Int,
        now: Date) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: entries.compactMap(\.totalTokens).reduce(0, +),
            last30DaysCostUSD: entries.compactMap(\.costUSD).reduce(0, +),
            currencyCode: "USD",
            historyDays: historyDays,
            historyCoverageIsEstablished: true,
            daily: entries,
            updatedAt: now)
    }

    private static func entry(
        day: String,
        cost: Double?,
        tokens: Int,
        model: String) -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: [.init(modelName: model, costUSD: cost, totalTokens: tokens)])
    }

    private static var gmtCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }
}
