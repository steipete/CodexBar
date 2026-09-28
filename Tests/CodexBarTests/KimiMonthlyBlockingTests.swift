import AppKit
import Foundation
import SwiftUI
import Testing
import XCTest
@testable import CodexBar
@testable import CodexBarCore

struct KimiMonthlyBlockingTests {
    static let now = Date(timeIntervalSince1970: 1_788_000_000)

    @Test(arguments: [false, true])
    func `exhausted membership blocks fresh Code windows without changing raw usage`(showUsed: Bool) throws {
        let snapshot = try Self.snapshot(ratio: 1)
        let model = try Self.model(snapshot, showUsed: showUsed)
        for id in ["primary", "secondary", "kimi-code-7d"] {
            let metric = try #require(model.metrics.first { $0.id == id })
            #expect(metric.percent == (showUsed ? 100 : 0))
            #expect(metric.statusText == "Blocked by monthly limit")
            #expect(metric.resetText == nil)
            #expect(metric.pacePercent == nil)
            #expect(metric.detailLeftText == nil)
            #expect(metric.detailRightText == nil)
            #expect(metric.sessionEquivalentDetail == nil)
        }
        #expect(snapshot.primary?.usedPercent == 0)
        #expect(snapshot.secondary?.usedPercent == 0)
        #expect(model.metrics.first { $0.id == "kimi-monthly" }?.statusText == nil)
    }

    @Test(arguments: [0.5, 0.999])
    func `available membership preserves Code windows`(ratio: Double) throws {
        let model = try Self.model(Self.snapshot(ratio: ratio))
        for id in ["primary", "secondary"] {
            let metric = try #require(model.metrics.first { $0.id == id })
            #expect(metric.percent == 100)
            #expect(metric.statusText == nil)
        }
    }

    @Test(arguments: [true, false])
    func `unknown or expired membership does not block`(unknown: Bool) throws {
        let monthly = NamedRateWindow(
            id: "kimi-monthly",
            title: "Total usage",
            window: Self.window(used: 100, minutes: 43200, reset: unknown ? nil : Self.now),
            usageKnown: !unknown)
        let snapshot = UsageSnapshot(
            primary: Self.window(used: 0, minutes: 10080),
            secondary: nil,
            extraRateWindows: [monthly],
            updatedAt: Self.now)
        let metric = try #require(Self.model(snapshot).metrics.first { $0.id == "primary" })
        #expect(metric.percent == 100)
        #expect(metric.statusText == nil)
    }

    @Test
    func `unknown monthly reset does not promise the shorter Code reset`() throws {
        let snapshot = UsageSnapshot(
            primary: Self.window(used: 0, minutes: 10080, reset: Self.now.addingTimeInterval(3600)),
            secondary: nil,
            extraRateWindows: [NamedRateWindow(
                id: "kimi-monthly", title: "Total usage", window: Self.window(used: 100, minutes: 43200))],
            updatedAt: Self.now)
        let metric = try #require(Self.model(snapshot).metrics.first { $0.id == "primary" })
        #expect(metric.statusText == "Blocked by monthly limit")
        #expect(metric.resetText == nil)
    }

    static func snapshot(ratio: Double) throws -> UsageSnapshot {
        let reset = ISO8601DateFormatter().string(from: self.now.addingTimeInterval(30 * 86400))
        // #3536 reports amountUsedRatio=1 while both Code counters are zero.
        let stats = try JSONDecoder().decode(KimiSubscriptionStatsResponse.self, from: Data("""
        {"subscriptionBalance":{"amountUsedRatio":\(ratio),"expireTime":"\(reset)",
        "overdrawn":true},"ratelimitCode7d":{"ratio":0.25,"enabled":true}}
        """.utf8))
        let weekly = KimiUsageDetail(
            limit: "100",
            used: "0",
            remaining: "100",
            resetTime: ISO8601DateFormatter().string(from: self.now.addingTimeInterval(4 * 86400 + 9 * 3600)))
        let session = KimiUsageDetail(
            limit: "100",
            used: "0",
            remaining: "100",
            resetTime: ISO8601DateFormatter().string(from: self.now.addingTimeInterval(3600)))
        return KimiUsageSnapshot(
            weekly: weekly,
            rateLimit: session,
            subscriptionBalance: stats.subscriptionBalance,
            subscriptionCodeWeeklyLimit: stats.ratelimitCode7d,
            updatedAt: self.now).toUsageSnapshot()
    }

    private static func window(used: Double, minutes: Int, reset: Date? = nil) -> RateWindow {
        RateWindow(usedPercent: used, windowMinutes: minutes, resetsAt: reset, resetDescription: nil)
    }

    static func model(_ snapshot: UsageSnapshot, showUsed: Bool = false) throws -> UsageMenuCardView.Model {
        let metadata = try #require(ProviderDefaults.metadata[.kimi])
        return UsageMenuCardView.Model.make(.init(
            provider: .kimi,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: showUsed,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: self.now))
    }
}

@MainActor
final class KimiMonthlyBlockingProofTests: XCTestCase {
    func test_syntheticBlockedWindows() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_KIMI_BLOCKING_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_KIMI_BLOCKING_PROOF_DIR for synthetic offscreen rendering")
        }
        let model = try KimiMonthlyBlockingTests.model(KimiMonthlyBlockingTests.snapshot(ratio: 1))
        let view = VStack(alignment: .leading, spacing: 16) {
            Text("Kimi Code · Synthetic monthly limit").font(.headline)
            ForEach(model.metrics) { metric in
                MetricRow(metric: metric, layoutMetric: metric, title: metric.title, progressColor: model.progressColor)
            }
        }
        .padding(20)
        .frame(width: 500, height: 400, alignment: .topLeading)
        .background(Color(NSColor.windowBackgroundColor))
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("kimi-monthly.png"))
    }
}
