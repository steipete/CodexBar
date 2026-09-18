import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// Opt-in rendering of the production chart views; no app launch, windows, accounts, or provider probes.
@MainActor
struct AntigravityHistoryNativeProofTests {
    @Test
    func `render populated observations and all unpriced cost disclosure`() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_ANTIGRAVITY_PROOF_DIR"] else { return }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = UsageStorePlanUtilizationTests.makeStore()
        let now = Date()
        for (index, used) in [18.0, 37, 64, 82, 20].enumerated() {
            let capturedAt = now.addingTimeInterval(Double(index - 4) * 3600)
            let snapshot = UsageSnapshot(
                primary: .init(usedPercent: used, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: capturedAt)
            await store.recordPlanUtilizationHistorySample(provider: .antigravity, snapshot: snapshot, now: capturedAt)
        }
        let histories = store.planUtilizationHistory(for: .antigravity)
        let chart = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
            histories: histories, provider: .antigravity, snapshot: nil, referenceDate: now)
        #expect(chart.usedPercents == [18, 37, 64, 82, 20])
        try self.render(
            PlanUtilizationHistoryChartMenuView(provider: .antigravity, histories: histories, width: 400),
            to: root.appendingPathComponent("antigravity-observations.png"))

        let fixture = try AntigravityLocalFixture()
        try fixture.database(blobs: [AntigravityLocalFixture.blob(), AntigravityLocalFixture.blob()])
        let report = try fixture.report().report
        #expect(report.data.reduce(0) { $0 + ($1.unpricedRequestCount ?? 0) } == 2)
        #expect(report.summary?.totalCostUSD == nil)
        let disclaimer = try #require(CostHistoryChartMenuView.coverageDisclaimer(
            provider: .antigravity, daily: report.data, totalCostUSD: nil))
        #expect(disclaimer.contains("2 unpriced requests"))
        try self.render(
            CostHistoryChartMenuView(
                provider: .antigravity,
                daily: report.data,
                totalCostUSD: nil,
                hidePersonalInfo: true,
                width: 400),
            to: root.appendingPathComponent("antigravity-all-unpriced-cost.png"))
        try JSONSerialization.data(withJSONObject: [
            "observationUsedPercents": chart.usedPercents,
            "selectedSeries": chart.selectedSeries ?? "",
            "costTotal": NSNull(),
            "costDisclaimer": disclaimer,
            "source": "Production SwiftUI views rendered from synthetic UsageStore and SQLite reader fixtures",
        ], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("antigravity-render-receipt.json"))
    }

    private func render(_ view: some View, to url: URL) throws {
        let hosting = NSHostingView(rootView: view
            .frame(width: 400)
            .padding(12)
            .background(Color.white)
            .environment(\.colorScheme, .light))
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url, options: .atomic)
    }
}
