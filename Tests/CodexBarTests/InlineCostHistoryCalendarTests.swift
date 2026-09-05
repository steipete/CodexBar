import AppKit
import SwiftUI
import Testing
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
struct InlineCostHistoryCalendarTests {
    @Test
    func `unpriced days retain calendar slots without becoming zero`() throws {
        let now = try InlineCostCalendarFixture.now()
        let snapshot = InlineCostCalendarFixture.snapshot(now: now, days: 4, covered: true)
        let points = try InlineCostCalendarFixture.model(snapshot).points
        #expect(points.map(\.id) == ["2026-08-21", "2026-08-22", "2026-08-23", "2026-08-24"])
        #expect(points.map { $0.value as Double? } == [3, 0, nil, 4])
        #expect(points[2].accessibilityValue == "2026-08-23: — · 100 tokens")
        #expect(points.map { $0.hoverDetail?.tokenCount } == [100, 0, 100, 100])
    }

    @Test
    func `incomplete history retains unknown missing days`() throws {
        let snapshot = try InlineCostCalendarFixture.snapshot(
            now: InlineCostCalendarFixture.now(),
            days: 4,
            covered: false)
        let points = try InlineCostCalendarFixture.model(snapshot).points
        #expect(points.map { $0.value as Double? } == [3, nil, nil, 4])
        #expect(!points.contains { $0.accessibilityValue.contains("$0.00") })
        #expect(points.map { $0.hoverDetail?.tokenCount } == [100, nil, 100, 100])
    }

    @Test
    func `other providers retain sparse histories with token only days`() throws {
        let snapshot = try InlineCostCalendarFixture.snapshot(
            now: InlineCostCalendarFixture.now(),
            days: 4,
            covered: true)
        let points = try InlineCostCalendarFixture.model(snapshot, provider: .claude).points
        #expect(points.map(\.id) == ["2026-08-21", "2026-08-23", "2026-08-24"])
        #expect(points.map(\.value) == [3, nil, 4])
        #expect(points.map { $0.hoverDetail?.tokenCount } == [100, 100, 100])
        #expect(points[1].accessibilityValue == "2026-08-23: — · 100 tokens")
    }

    @Test
    func `negative cost and token values remain unknown`() throws {
        let now = try InlineCostCalendarFixture.now()
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 0,
            sessionCostUSD: 0,
            last30DaysTokens: 0,
            last30DaysCostUSD: 0,
            historyDays: 1,
            daily: [InlineCostCalendarFixture.entry("2026-08-24", cost: -1, totalTokens: -1)],
            updatedAt: now)
        let point = try #require(InlineCostCalendarFixture.model(snapshot, provider: .claude).points.first)

        #expect(point.value == nil)
        #expect(point.hoverDetail == nil)
        #expect(point.accessibilityValue == "2026-08-24: Unknown")
    }

    @Test(arguments: [
        ("2026-08-23T16:30:00Z", 1, ["2026-08-23"]),
        ("2026-03-10T19:00:00Z", 4, ["2026-03-07", "2026-03-08", "2026-03-09", "2026-03-10"]),
        ("2026-11-02T20:00:00Z", 4, ["2026-10-30", "2026-10-31", "2026-11-01", "2026-11-02"]),
    ])
    func `pinned bucket calendar preserves midnight and DST dates`(
        timestamp: String, days: Int, expected: [String]) throws
    {
        let now = try #require(ISO8601DateFormatter().date(from: timestamp))
        let calendar = try InlineCostCalendarFixture.calendar("America/Los_Angeles")
        let lastDay = try #require(expected.last)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 100,
            sessionCostUSD: 3,
            last30DaysTokens: 100,
            last30DaysCostUSD: 3,
            historyDays: days,
            daily: [InlineCostCalendarFixture.entry(lastDay, cost: 3)],
            updatedAt: now)
        let points = try InlineCostCalendarFixture.model(snapshot, calendar: calendar).points
        #expect(points.map(\.id) == expected)
        #expect(points.last?.value == 3)
        // The snapshot owns its range even if the menu is reopened on a later day.
        let stale = try InlineCostCalendarFixture.model(
            snapshot, calendar: calendar, now: now.addingTimeInterval(86400 * 10))
        #expect(stale.points == points)
    }

    @Test(arguments: [1, 4, 30, 90, 365])
    func `all bar slots fit the menu width`(count: Int) {
        for width: CGFloat in [0, 120, 286, 500] {
            let layout = InlineUsageBarLayout(width: width, count: count)
            #expect(layout.barWidth >= 0)
            #expect(layout.spacing >= 0)
            let lastEdge = CGFloat(count) * layout.barWidth + CGFloat(count - 1) * layout.spacing
            #expect(abs(lastEdge - width) < 0.00001)
        }
    }

    @Test(arguments: [1, 4, 30, 90, 365])
    func `bar hover resolves dynamic geometry and right to left order`(count: Int) {
        let width: CGFloat = 286
        let layout = InlineUsageBarLayout(width: width, count: count)
        let firstCenter = layout.barWidth / 2
        let lastCenter = CGFloat(count - 1) * (layout.barWidth + layout.spacing) + layout.barWidth / 2

        #expect(layout.index(atX: firstCenter) == 0)
        #expect(layout.index(atX: lastCenter) == count - 1)
        #expect(layout.index(atX: firstCenter, layoutDirection: .rightToLeft) == count - 1)
        #expect(layout.index(atX: lastCenter, layoutDirection: .rightToLeft) == 0)
        #expect(layout.index(atX: 0) == 0)
        #expect(layout.index(atX: width) == count - 1)
        #expect(layout.index(atX: -1) == nil)
        #expect(layout.index(atX: width + 1) == nil)

        if count > 1, layout.spacing > 0 {
            let gap = layout.barWidth + layout.spacing / 2
            if layout.spacing < 1 {
                #expect(layout.index(atX: gap) != nil)
            } else {
                #expect(layout.index(atX: gap) == nil)
            }
        }
        let selectionStrokeWidth = layout.selectionStrokeWidth(barHeight: 1)
        #expect(selectionStrokeWidth <= layout.barWidth / 2)
        #expect(selectionStrokeWidth <= 0.5)
    }

    @Test
    func `empty bar layout never selects a point`() {
        let layout = InlineUsageBarLayout(width: 286, count: 0)
        #expect(layout.barWidth == 0)
        #expect(layout.index(atX: 0) == nil)
        #expect(layout.index(atX: 143) == nil)
    }

    @Test
    func `hover selection retains a bar across gaps and clears on exit or unknown days`() {
        let detail = InlineUsageDashboardModel.HoverDetail(
            dateLabel: "2026-08-21",
            cost: 3,
            tokenCount: 100,
            currencyCode: "USD")
        let points = [
            InlineUsageDashboardModel.Point(
                id: "first",
                label: "1",
                value: 3,
                accessibilityValue: detail.summary,
                hoverDetail: detail),
            InlineUsageDashboardModel.Point(
                id: "unknown",
                label: "2",
                value: nil,
                accessibilityValue: "Unknown"),
            InlineUsageDashboardModel.Point(
                id: "last",
                label: "3",
                value: 4,
                accessibilityValue: detail.summary,
                hoverDetail: detail),
        ]
        let layout = InlineUsageBarLayout(width: 32, count: points.count)
        let firstCenter = layout.barWidth / 2
        let gap = layout.barWidth + layout.spacing / 2
        let unknownCenter = layout.barWidth + layout.spacing + layout.barWidth / 2

        let first = InlineUsageBarHoverSelection.pointID(
            current: nil,
            locationX: firstCenter,
            layout: layout,
            layoutDirection: .leftToRight,
            points: points)
        #expect(first == "first")
        #expect(InlineUsageBarHoverSelection.pointID(
            current: first,
            locationX: gap,
            layout: layout,
            layoutDirection: .leftToRight,
            points: points) == "first")
        #expect(InlineUsageBarHoverSelection.pointID(
            current: "stale",
            locationX: gap,
            layout: layout,
            layoutDirection: .leftToRight,
            points: points) == nil)
        #expect(InlineUsageBarHoverSelection.pointID(
            current: first,
            locationX: unknownCenter,
            layout: layout,
            layoutDirection: .leftToRight,
            points: points) == nil)
        #expect(InlineUsageBarHoverSelection.pointID(
            current: first,
            locationX: nil,
            layout: layout,
            layoutDirection: .leftToRight,
            points: points) == nil)
        #expect(InlineUsageBarHoverSelection.pointID(
            current: first,
            locationX: 33,
            layout: layout,
            layoutDirection: .leftToRight,
            points: points) == nil)
        #expect(InlineUsageBarHoverSelection.pointID(
            current: nil,
            locationX: firstCenter,
            layout: layout,
            layoutDirection: .rightToLeft,
            points: points) == "last")

        let refreshedPoints = points.map { point in
            InlineUsageDashboardModel.Point(
                id: point.id,
                label: point.label,
                value: point.value.map { $0 + 1 },
                accessibilityValue: point.accessibilityValue,
                hoverDetail: point.hoverDetail)
        }
        #expect(InlineUsageBarHoverSelection.reconciledPointID(
            current: first,
            previousPoints: points,
            points: refreshedPoints) == "first")
        #expect(InlineUsageBarHoverSelection.reconciledPointID(
            current: first,
            previousPoints: points,
            points: Array(points.dropFirst())) == nil)
    }

    @Test
    func `native bounded scan keeps unknown dates until catch up completes`() async throws {
        let (partial, covered) = try await InlineCostCalendarFixture.scannedSnapshots()
        let calendar = try InlineCostCalendarFixture.calendar("UTC")
        #expect(!partial.daily.isEmpty)
        #expect(!partial.historyCoverageIsEstablished)
        let pendingPoints = try InlineCostCalendarFixture.model(partial, calendar: calendar).points
        #expect(pendingPoints.count == 4)
        #expect(pendingPoints[0].value != nil)
        #expect(pendingPoints[1].value == nil)
        #expect(pendingPoints[2].value == nil)
        #expect(pendingPoints[3].value == nil)

        #expect(covered.historyCoverageIsEstablished)
        let points = try InlineCostCalendarFixture.model(covered, calendar: calendar).points
        #expect(points.map(\.id) == pendingPoints.map(\.id))
        #expect(points[0].value == pendingPoints[0].value)
        #expect(points[1].value == 0)
        #expect(points[2].value == nil)
        #expect((points[3].value ?? 0) > 0)
        #expect(covered.last30DaysTokens == 3_000_000)
    }
}

enum InlineCostCalendarFixture {
    static func now() throws -> Date {
        try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 24, hour: 12)))
    }

    static func snapshot(now: Date, days: Int, covered: Bool) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: 400,
            sessionCostUSD: 4,
            last30DaysTokens: 800,
            last30DaysCostUSD: 7,
            historyDays: days,
            historyCoverageIsEstablished: covered,
            daily: [
                self.entry("2026-08-21", cost: 3),
                self.entry("2026-08-23", cost: nil),
                self.entry("2026-08-24", cost: 4),
            ],
            updatedAt: now)
    }

    static func entry(_ date: String, cost: Double?, totalTokens: Int = 100) -> CostUsageDailyReport.Entry {
        .init(
            date: date,
            inputTokens: totalTokens,
            outputTokens: 0,
            totalTokens: totalTokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
    }

    static func model(
        _ snapshot: CostUsageTokenSnapshot,
        provider: UsageProvider = .codex,
        calendar: Calendar = .current,
        now: Date? = nil) throws
        -> InlineUsageDashboardModel
    {
        let model = try UsageMenuCardView.Model.make(.init(
            provider: provider,
            metadata: XCTUnwrap(ProviderDefaults.metadata[provider]),
            snapshot: UsageSnapshot(primary: nil, secondary: nil, updatedAt: snapshot.updatedAt),
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: snapshot,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            preferredCurrencyCode: "USD",
            costUsageBucketCalendar: calendar,
            now: now ?? snapshot.updatedAt))
        return try XCTUnwrap(model.inlineUsageDashboard)
    }

    static func calendar(_ identifier: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: identifier))
        return calendar
    }

    static func scannedSnapshots(historyDays: Int = 4) async throws
    -> (CostUsageTokenSnapshot, CostUsageTokenSnapshot) {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let calendar = try Self.calendar("UTC")
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-24T18:00:00Z"))
        func write(day: Int, model: String) throws {
            let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: 12)))
            _ = try env.writeCodexSessionFile(day: date, filename: "fixture-\(day).jsonl", contents: env.jsonl([
                ["type": "turn_context", "timestamp": env.isoString(for: date), "payload": ["model": model]],
                [
                    "type": "event_msg", "timestamp": env.isoString(for: date.addingTimeInterval(1)),
                    "payload": ["type": "token_count", "info": [
                        "model": model,
                        "last_token_usage": ["input_tokens": 1_000_000, "cached_input_tokens": 0, "output_tokens": 0],
                    ]],
                ],
            ]))
        }
        try write(day: 21, model: "openai/gpt-5.4")
        try write(day: 23, model: "fictional-unpriced-calendar-model")
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.calendar = calendar
        options.refreshMinIntervalSeconds = 0
        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            environment: [:],
            now: now,
            historyDays: historyDays,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: options)
        try write(day: 24, model: "openai/gpt-5.4")
        options.maxCodexSessionFileBytes = 1
        options.maxCodexScanBytesPerRefresh = 1
        let partial = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            environment: [:],
            now: now.addingTimeInterval(1),
            historyDays: historyDays,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: options)
        options.maxCodexSessionFileBytes = 0
        options.maxCodexScanBytesPerRefresh = 0
        let covered = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            environment: [:],
            now: now.addingTimeInterval(2),
            historyDays: historyDays,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: options)
        return (partial, covered)
    }
}

@MainActor
final class InlineCostHistoryScreenshotTests: XCTestCase {
    func test_renderCalendarWindows() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_INLINE_COST_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_INLINE_COST_PROOF_DIR to render the production inline cost chart.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var models: [(String, InlineUsageDashboardModel)] = []
        for days in [1, 4, 30, 365] {
            for covered in [false, true] {
                let snapshot = try InlineCostCalendarFixture.snapshot(
                    now: InlineCostCalendarFixture.now(), days: days, covered: covered)
                let model = try InlineCostCalendarFixture.model(snapshot)
                models.append(("calendar-\(days)-\(covered ? "covered" : "partial")", model))
            }
        }
        let calendar = try InlineCostCalendarFixture.calendar("UTC")
        for days in [1, 4, 30, 365] {
            let (partial, covered) = try await InlineCostCalendarFixture.scannedSnapshots(historyDays: days)
            if !partial.daily.isEmpty {
                try models.append((
                    "native-\(days)-partial",
                    InlineCostCalendarFixture.model(partial, calendar: calendar)))
            }
            try models.append(("native-\(days)-covered", InlineCostCalendarFixture.model(covered, calendar: calendar)))
        }
        for (stem, model) in models {
            for dark in [false, true] {
                let view = InlineUsageDashboardContent(model: model)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(width: 310)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.displayScale, 2)
                    .environment(\.accessibilityEnabled, true)
                    .background(Color(nsColor: .windowBackgroundColor))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
                hosting.layoutSubtreeIfNeeded()
                let representation = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: representation)
                let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
                let name = "\(stem)-\(dark ? "dark" : "light")"
                try data.write(to: directory.appendingPathComponent("\(name).png"))
                let accessibility = Self.accessibilityText(hosting)
                try accessibility.write(
                    to: directory.appendingPathComponent("\(name)-accessibility.txt"),
                    atomically: true,
                    encoding: .utf8)
                if model.points.count == 4 {
                    for point in model.points {
                        XCTAssertTrue(accessibility.contains(point.accessibilityValue), point.accessibilityValue)
                    }
                }
                XCTAssertEqual(hosting.bounds.width, 310, accuracy: 0.1)

                if stem == "calendar-4-covered" || stem == "calendar-365-covered" {
                    let trackingView = try XCTUnwrap(Self.firstTrackingView(in: hosting))
                    XCTAssertGreaterThan(trackingView.bounds.width, 0)
                    let layout = InlineUsageBarLayout(width: trackingView.bounds.width, count: model.points.count)
                    let selectedIndex = model.points.count - 1
                    let selectedX = CGFloat(selectedIndex) * (layout.barWidth + layout.spacing) +
                        layout.barWidth / 2
                    trackingView.onMoved?(CGPoint(x: selectedX, y: trackingView.bounds.midY))
                    try await Task.sleep(for: .milliseconds(50))
                    hosting.layoutSubtreeIfNeeded()

                    let hoveredRepresentation = try XCTUnwrap(
                        hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: hoveredRepresentation)
                    let hoveredData = try XCTUnwrap(
                        hoveredRepresentation.representation(using: .png, properties: [:]))
                    try hoveredData.write(to: directory.appendingPathComponent("\(name)-hover.png"))
                    XCTAssertNotEqual(data, hoveredData)

                    let selectedDetail = try XCTUnwrap(model.points[selectedIndex].hoverDetail)
                    let hoveredAccessibility = Self.accessibilityText(hosting)
                    XCTAssertTrue(hoveredAccessibility.contains(selectedDetail.summary))
                    XCTAssertEqual(
                        hoveredAccessibility.components(separatedBy: selectedDetail.summary).count - 1,
                        1,
                        "The visual hover summary must not duplicate the selected bar's VoiceOver label.")
                }
            }
        }
    }

    private static func firstTrackingView(in root: NSView) -> MouseLocationReader.TrackingView? {
        if let trackingView = root as? MouseLocationReader.TrackingView {
            return trackingView
        }
        for subview in root.subviews {
            if let trackingView = self.firstTrackingView(in: subview) {
                return trackingView
            }
        }
        return nil
    }

    private static func accessibilityText(_ element: Any, depth: Int = 0) -> String {
        guard depth < 30, let node = element as? NSObject else { return "" }
        let labelSelector = #selector(NSAccessibilityProtocol.accessibilityLabel)
        let childrenSelector = #selector(NSAccessibilityProtocol.accessibilityChildren)
        let label = node.responds(to: labelSelector)
            ? node.perform(labelSelector)?.takeUnretainedValue() as? String ?? "" : ""
        let children = node.responds(to: childrenSelector)
            ? node.perform(childrenSelector)?.takeUnretainedValue() as? [Any] ?? [] : []
        return ([label] + children.map { self.accessibilityText($0, depth: depth + 1) }).joined(separator: "\n")
    }
}
