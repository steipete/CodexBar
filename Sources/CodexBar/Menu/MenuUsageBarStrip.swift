import CodexBarCore
import SwiftUI

protocol MenuUsageBarHoverPoint {
    var id: String { get }
    var hoverSummary: String? { get }
}

struct MenuUsageBarPoint: Identifiable, Equatable, MenuUsageBarHoverPoint {
    let id: String
    let value: Double?
    var isPending = false
    var hoverSummary: String?
    var accessibilityValue = ""
}

extension InlineUsageDashboardModel.Point: MenuUsageBarHoverPoint {
    var hoverSummary: String? {
        self.hoverDetail?.summary
    }

    var menuUsageBarPoint: MenuUsageBarPoint {
        .init(
            id: self.id,
            value: self.value,
            hoverSummary: self.hoverSummary,
            accessibilityValue: self.accessibilityValue)
    }
}

/// Shared geometry and alpha math for native menu graphs and SwiftUI strips.
enum MenuUsageBarMetrics {
    static func scale(values: [Double], roundedHeadroom: Bool = false) -> UsageChartScale {
        let scale = UsageChartScale(values: values)
        guard roundedHeadroom, scale.maximum > 0 else { return scale }
        let magnitude = pow(10, floor(log10(scale.maximum)))
        guard magnitude.isFinite, magnitude > 0 else { return scale }
        let normalized = scale.maximum / magnitude
        let step = [1.0, 2, 5, 10].first { $0 > normalized } ?? 10
        let ceiling = step * magnitude
        return UsageChartScale(values: [ceiling.isFinite ? ceiling : scale.maximum])
    }

    static func opacity(
        value: Double?,
        isPending: Bool = false,
        scale: UsageChartScale,
        highlighted: Bool) -> Double
    {
        if isPending { return 0.22 }
        guard let value else { return 0 }
        let ratio = max(0.18, scale.fraction(for: value))
        return highlighted ? 0.55 + ratio * 0.35 : 0.42 + ratio * 0.58
    }

    static func height(
        value: Double?,
        isPending: Bool = false,
        scale: UsageChartScale,
        available: CGFloat) -> CGFloat
    {
        guard !isPending, let value else { return 1 }
        let ratio = scale.fraction(for: value)
        guard ratio > 0 else { return 1 }
        // Preserve the daily chart's geometry: the 0.18 floor belongs to alpha, not height.
        return max(3, CGFloat(ratio) * available)
    }
}

extension EnvironmentValues {
    /// Optional selection control for previews and native render proofs.
    @Entry var menuUsageBarSelection: Binding<String?>?
}

struct MenuUsageBarStrip: View {
    let points: [MenuUsageBarPoint]
    let baseColor: Color
    var roundedHeadroom = false
    var selection: Binding<String?>?
    @Environment(\.menuItemHighlighted) private var isHighlighted
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var localSelection: String?

    private var selectedPointID: Binding<String?> {
        self.selection ?? self.$localSelection
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = InlineUsageBarLayout(width: geometry.size.width, count: self.points.count)
            let scale = MenuUsageBarMetrics.scale(
                values: self.points.filter { !$0.isPending }.compactMap(\.value),
                roundedHeadroom: self.roundedHeadroom)
            HStack(alignment: .bottom, spacing: layout.spacing) {
                ForEach(self.points) { point in
                    let height = MenuUsageBarMetrics.height(
                        value: point.value,
                        isPending: point.isPending,
                        scale: scale,
                        available: geometry.size.height)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(self.fill(point, scale: scale))
                        .frame(width: layout.barWidth, height: height)
                        .overlay {
                            if point.id == self.selectedPointID.wrappedValue {
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .strokeBorder(
                                        MenuHighlightStyle.primary(self.isHighlighted),
                                        lineWidth: layout.selectionStrokeWidth(barHeight: height))
                            }
                        }
                        .accessibilityLabel(point.accessibilityValue)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .overlay(alignment: .bottomLeading) {
                Rectangle()
                    .fill(MenuHighlightStyle.secondary(self.isHighlighted).opacity(0.22))
                    .frame(height: 1)
            }
            // Behind the bars so the caller's chart tap still opens its detail view.
            .background {
                if self.points.contains(where: { $0.hoverSummary != nil }) {
                    MouseLocationReader { location in
                        self.select(InlineUsageBarHoverSelection.pointID(
                            current: self.selectedPointID.wrappedValue,
                            locationX: location?.x,
                            layout: layout,
                            layoutDirection: self.layoutDirection,
                            points: self.points))
                    }
                }
            }
            .onChange(of: geometry.size.width) { _, _ in self.select(nil) }
            .onChange(of: self.points) { previous, points in
                self.select(InlineUsageBarHoverSelection.reconciledPointID(
                    current: self.selectedPointID.wrappedValue, previousPoints: previous, points: points))
            }
            .onChange(of: self.layoutDirection) { _, _ in self.select(nil) }
        }
    }

    private func select(_ pointID: String?) {
        guard self.selectedPointID.wrappedValue != pointID else { return }
        self.selectedPointID.wrappedValue = pointID
    }

    private func fill(_ point: MenuUsageBarPoint, scale: UsageChartScale) -> Color {
        let opacity = MenuUsageBarMetrics.opacity(
            value: point.value,
            isPending: point.isPending,
            scale: scale,
            highlighted: self.isHighlighted)
        let color = point.isPending ? MenuHighlightStyle.secondary(self.isHighlighted)
            : self.isHighlighted ? MenuHighlightStyle.selectionText : self.baseColor
        return color.opacity(opacity)
    }
}

struct InlineUsageBarLayout {
    let spacing: CGFloat
    let barWidth: CGFloat
    private let width: CGFloat
    private let barCount: Int

    init(width: CGFloat, count: Int) {
        self.width = max(0, width)
        self.barCount = max(0, count)
        let layoutCount = max(1, self.barCount)
        self.spacing = self.barCount <= 1 ? 0 : min(2, self.width / CGFloat(layoutCount) / 4)
        self.barWidth = self.barCount == 0
            ? 0
            : max(0, (self.width - self.spacing * CGFloat(self.barCount - 1)) / CGFloat(self.barCount))
    }

    func selectionStrokeWidth(barHeight: CGFloat) -> CGFloat {
        min(1, self.barWidth / 2, max(0, barHeight) / 2)
    }

    func contains(_ locationX: CGFloat) -> Bool {
        self.barCount > 0 && self.width > 0 && locationX >= 0 && locationX <= self.width
    }

    func index(atX locationX: CGFloat, layoutDirection: LayoutDirection = .leftToRight) -> Int? {
        guard self.contains(locationX), self.barWidth > 0 else { return nil }

        let stride = self.barWidth + self.spacing
        guard stride > 0 else { return nil }
        let resolvedX = layoutDirection == .rightToLeft ? self.width - locationX : locationX
        if self.spacing < 1 {
            let nearest = Int(((resolvedX - self.barWidth / 2) / stride).rounded())
            return min(max(nearest, 0), self.barCount - 1)
        }
        let index = min(Int(resolvedX / stride), self.barCount - 1)
        let offset = resolvedX - CGFloat(index) * stride
        let tolerance = max(1, self.width) * CGFloat.ulpOfOne * 8
        return offset <= self.barWidth + tolerance ? index : nil
    }
}

enum InlineUsageBarHoverSelection {
    static func reconciledPointID<Point: MenuUsageBarHoverPoint>(
        current: String?,
        previousPoints: [Point],
        points: [Point]) -> String?
    {
        guard previousPoints.map(\.id) == points.map(\.id), let current else { return nil }
        return points.contains { $0.id == current && $0.hoverSummary != nil } ? current : nil
    }

    static func pointID(
        current: String?,
        locationX: CGFloat?,
        layout: InlineUsageBarLayout,
        layoutDirection: LayoutDirection,
        points: [some MenuUsageBarHoverPoint]) -> String?
    {
        guard let locationX else { return nil }
        guard layout.contains(locationX) else { return nil }
        guard let index = layout.index(atX: locationX, layoutDirection: layoutDirection) else {
            return current.flatMap { currentID in
                points.contains { $0.id == currentID && $0.hoverSummary != nil } ? currentID : nil
            }
        }
        guard points.indices.contains(index), points[index].hoverSummary != nil else { return nil }
        return points[index].id
    }
}
