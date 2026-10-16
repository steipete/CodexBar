import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct CostHistoryResizeTests {
    @Test(arguments: [false, true])
    func `hover keeps chart position stable with dynamic or constrained menu sizing`(constrained: Bool) throws {
        let daily = (1...2).map { day in
            CostUsageDailyReport.Entry(
                date: "2026-09-0\(day)",
                inputTokens: 1000,
                outputTokens: 100,
                totalTokens: 1100,
                costUSD: Double(day),
                modelsUsed: nil,
                modelBreakdowns: (0..<(3 - day)).map { index in
                    CostUsageDailyReport.ModelBreakdown(
                        modelName: "fixture-model-\(index)", costUSD: 1, totalTokens: 550)
                })
        }
        let relay = ResizeTestRelay()
        let hosting = MenuHostingView(rootView: CostHistoryChartMenuView(
            provider: .claude,
            daily: daily,
            totalCostUSD: 3,
            hidePersonalInfo: true,
            width: 400,
            onDetailHeightChanged: { delta, updateContent in
                if let viewport = relay.viewport {
                    viewport.adjustDocumentHeight(by: delta, updateContent: updateContent)
                } else {
                    updateContent()
                }
            }))
        let growth = CostHistoryChartMenuView.maximumDetailHeightGrowth(provider: .claude, daily: daily)
        let viewport = CostHistoryMenuScrollView(
            hosting: hosting,
            width: 400,
            maximumHeight: 620,
            maximumHeightGrowth: growth,
            availableHeightBelowAnchor: constrained ? 1 : nil)
        relay.viewport = viewport
        hosting.layoutSubtreeIfNeeded()
        let tracking = try #require(Self.trackingView(in: hosting))
        let detailScroller = try #require(Self.detailScroller(in: hosting))
        let baselineHeight = hosting.frame.height
        let reservedHeight = viewport.frame.height
        let chartTop = tracking.convert(.zero, to: viewport).y
        #expect(chartTop <= 20)
        for fraction in [0.3, 0.8, 0.3, 0.8] {
            tracking.onMoved?(CGPoint(x: tracking.bounds.width * fraction, y: tracking.bounds.midY))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            hosting.layoutSubtreeIfNeeded()
            let expectedHeight = baselineHeight + (fraction < 0.5 ? 42 : 0)
            #expect(viewport.frame.height == (constrained ? reservedHeight : expectedHeight))
            #expect(viewport.intrinsicContentSize.height == viewport.frame.height)
            #expect(Self.detailScroller(in: hosting) === detailScroller)
            #expect(hosting.frame.height == expectedHeight)
            #expect(tracking.convert(.zero, to: viewport).y == chartTop)
            #expect(viewport.contentView.bounds.origin == .zero)
        }
    }

    private static func detailScroller(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        return view.subviews.lazy.compactMap { self.detailScroller(in: $0) }.first
    }

    private static func trackingView(in view: NSView) -> MouseLocationReader.TrackingView? {
        if let tracking = view as? MouseLocationReader.TrackingView { return tracking }
        return view.subviews.lazy.compactMap { self.trackingView(in: $0) }.first
    }
}

@MainActor
private final class ResizeTestRelay {
    weak var viewport: CostHistoryMenuScrollView?
}
