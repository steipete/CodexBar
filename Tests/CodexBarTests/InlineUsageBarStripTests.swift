import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

struct InlineUsageBarStripTests {
    @Test
    func `daily geometry and model projection retain their original output`() {
        let detail = InlineUsageDashboardModel.HoverDetail(
            dateLabel: "Jan 1", cost: 0.25, tokenCount: 1000, currencyCode: "USD")
        let points: [InlineUsageDashboardModel.Point] = [
            .init(id: "low", label: "1", value: 0.01, accessibilityValue: detail.summary, hoverDetail: detail),
            .init(id: "zero", label: "2", value: 0, accessibilityValue: "Zero"),
            .init(id: "missing", label: "3", value: nil, accessibilityValue: "Unknown"),
            .init(id: "peak", label: "4", value: 0.5, accessibilityValue: detail.summary, hoverDetail: detail),
        ]
        let original = points
        let projected = points.map(\.menuUsageBarPoint)
        let scale = MenuUsageBarMetrics.scale(values: projected.compactMap(\.value))
        #expect(scale == UsageChartScale(values: [0.01, 0, 0.5]))
        #expect(scale.maximum == 0.5)
        for (point, output) in zip(points, projected) {
            #expect(output.id == point.id)
            #expect(output.value == point.value)
            #expect(output.hoverSummary == point.hoverDetail?.summary)
            #expect(output.accessibilityValue == point.accessibilityValue)
            #expect(!output.isPending)
            let ratio = point.value.map { scale.fraction(for: $0) } ?? 0
            let expectedHeight = ratio > 0 ? max(3, CGFloat(ratio) * 44) : 1
            #expect(MenuUsageBarMetrics.height(value: output.value, scale: scale, available: 44) == expectedHeight)
            for highlighted in [false, true] {
                let r = max(0.18, ratio)
                let expectedOpacity = point.value == nil ? 0 : highlighted ? 0.55 + r * 0.35 : 0.42 + r * 0.58
                #expect(MenuUsageBarMetrics.opacity(
                    value: output.value,
                    scale: scale,
                    highlighted: highlighted) == expectedOpacity)
            }
        }
        #expect(points == original)
    }

    @Test
    func `rounded throughput scale reserves headroom and pending values stay on the baseline`() {
        let scale = MenuUsageBarMetrics.scale(values: [49_000_000, 151_000_000], roundedHeadroom: true)
        #expect(scale.maximum == 200_000_000)
        #expect(MenuUsageBarMetrics.height(value: 151_000_000, scale: scale, available: 44) == 33.22)
        #expect(MenuUsageBarMetrics.height(value: 0, scale: scale, available: 44) == 1)
        #expect(MenuUsageBarMetrics.height(value: nil, scale: scale, available: 44) == 1)
        for highlighted in [false, true] {
            #expect(MenuUsageBarMetrics.opacity(
                value: 151_000_000,
                isPending: true,
                scale: scale,
                highlighted: highlighted) == 0.22)
            #expect(MenuUsageBarMetrics.height(
                value: 151_000_000,
                isPending: true,
                scale: scale,
                available: 44) == 1)
            #expect(MenuUsageBarMetrics.opacity(value: nil, scale: scale, highlighted: highlighted) == 0)
            let opacity = MenuUsageBarMetrics.opacity(value: 49_000_000, scale: scale, highlighted: highlighted)
            #expect(opacity == (highlighted ? 0.55 + 0.245 * 0.35 : 0.42 + 0.245 * 0.58))
        }
        #expect(MenuUsageBarMetrics.scale(values: [0, .nan, .infinity], roundedHeadroom: true).maximum == 0)
    }

    @Test
    func `shared hover mapping preserves gaps RTL and refreshed selection semantics`() {
        let points: [MenuUsageBarPoint] = [
            .init(id: "first", value: 10, hoverSummary: "First"),
            .init(id: "missing", value: nil),
            .init(id: "pending", value: 0, isPending: true, hoverSummary: "Reporting"),
        ]
        let layout = InlineUsageBarLayout(width: 32, count: points.count)
        let center = layout.barWidth / 2
        #expect(InlineUsageBarHoverSelection.pointID(
            current: nil,
            locationX: center,
            layout: layout,
            layoutDirection: .leftToRight,
            points: points) == "first")
        #expect(InlineUsageBarHoverSelection.pointID(
            current: nil,
            locationX: center,
            layout: layout,
            layoutDirection: .rightToLeft,
            points: points) == "pending")
        #expect(InlineUsageBarHoverSelection.pointID(
            current: "first",
            locationX: layout.barWidth + layout.spacing / 2,
            layout: layout,
            layoutDirection: .leftToRight,
            points: points) == "first")
        #expect(InlineUsageBarHoverSelection.pointID(
            current: "first",
            locationX: nil,
            layout: layout,
            layoutDirection: .leftToRight,
            points: points) == nil)
        #expect(InlineUsageBarHoverSelection.reconciledPointID(
            current: "pending",
            previousPoints: points,
            points: points) == "pending")
        #expect(InlineUsageBarHoverSelection.reconciledPointID(
            current: "first",
            previousPoints: points,
            points: Array(points.dropFirst())) == nil)
    }
}
