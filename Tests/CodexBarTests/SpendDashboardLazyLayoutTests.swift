import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

@MainActor
final class SpendDashboardLazyLayoutTests: XCTestCase {
    func test_offscreenDrawingLayersAreDeferredUntilScrolling() async throws {
        _ = NSApplication.shared
        let day = Date(timeIntervalSince1970: 1_793_836_800)
        let providers = Array(UsageProvider.allCases.prefix(20))
        let group = SpendDashboardModel.CurrencyGroup(
            currencyCode: "USD",
            providers: providers.enumerated().map { index, provider in
                .init(
                    id: provider.rawValue,
                    rank: index + 1,
                    provider: provider,
                    displayName: "Synthetic \(index)",
                    totalTokens: 100,
                    totalCost: 1,
                    coveredDayCount: 1)
            },
            models: [],
            dailyPoints: providers.map {
                .init(
                    sourceID: $0.rawValue,
                    provider: $0,
                    providerName: "Synthetic",
                    day: day,
                    cost: 1,
                    stackStart: 0,
                    stackEnd: 1)
            },
            totalTokens: 2000,
            totalCost: 20,
            coveredDayCount: 1,
            chartDomain: day...day.addingTimeInterval(40 * 86400),
            modelHistoryCompleteness: .complete,
            timeZone: .gmt)
        let host = NSHostingView(rootView: ScrollView {
            LazyVStack {
                SpendDashboardCurrencySection(group: group, requestedDays: 40).padding(24)
            }
        }.frame(width: 760, height: 480))
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 760, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        await Self.layout(host)

        let initialLayerCount = Self.layerCount(host)
        let scroll = try XCTUnwrap(Self.views(host).compactMap { $0 as? NSScrollView }.first)
        var maximumLayerCount = initialLayerCount
        for _ in 0..<20 {
            let document = try XCTUnwrap(scroll.documentView)
            let next = min(
                document.bounds.height - scroll.contentView.bounds.height,
                scroll.contentView.bounds.minY + scroll.contentView.bounds.height / 2)
            document.scroll(NSPoint(x: 0, y: max(0, next)))
            await Self.layout(host)
            let layerCount = Self.layerCount(host)
            maximumLayerCount = max(maximumLayerCount, layerCount)
            if maximumLayerCount > initialLayerCount { break }
        }
        XCTAssertGreaterThan(maximumLayerCount, initialLayerCount)
    }

    private static func layout(_ host: NSView) async {
        for _ in 0..<4 {
            host.window?.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            host.window?.displayIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private static func views(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(self.views)
    }

    private static func layerCount(_ host: NSView) -> Int {
        func descendants(_ layer: CALayer) -> [CALayer] {
            [layer] + (layer.sublayers ?? []).flatMap(descendants)
        }
        return Set(self.views(host).compactMap(\.layer).flatMap(descendants).map(ObjectIdentifier.init)).count
    }
}
