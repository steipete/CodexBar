import CodexBarCore
import SwiftUI

struct ProviderDetailSectionsContent: View {
    let sections: [ProviderDetailSection]
    let chartColor: Color
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(self.sections.enumerated()), id: \.offset) { index, section in
                if index > 0 {
                    Divider()
                }
                self.section(section)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section(_ section: ProviderDetailSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = section.title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .textCase(.uppercase)
                    .lineLimit(1)
            }
            ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.label)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(row.value)
                            .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                            .fontWeight(.medium)
                        if let secondaryValue = row.secondaryValue {
                            Text(secondaryValue)
                                .font(.caption2)
                                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        }
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
            if let chart = section.chart {
                ProviderDetailChartContent(chart: chart, color: self.chartColor)
            }
        }
    }
}

private struct ProviderDetailChartContent: View {
    let chart: ProviderDetailSection.Chart
    let color: Color
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if self.chart.title != nil || self.chart.unit != nil {
                HStack(spacing: 6) {
                    if let title = self.chart.title {
                        Text(title)
                            .font(.caption2.weight(.semibold))
                    }
                    Spacer(minLength: 0)
                    if let unit = self.chart.unit {
                        Text(unit)
                            .font(.caption2)
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                .lineLimit(1)
            }
            Group {
                switch self.chart.kind {
                case .bars:
                    self.bars
                case .line:
                    self.line
                }
            }
            .frame(height: 58)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(self.accessibilityLabel)
        }
    }

    private var bars: some View {
        GeometryReader { geometry in
            let scale = UsageChartScale(values: self.chart.points.map(\.value))
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(self.chart.points.enumerated()), id: \.offset) { _, point in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(self.fillColor(value: point.value, scale: scale))
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.height(value: point.value, scale: scale, available: geometry.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .overlay(alignment: .bottomLeading) {
                Rectangle()
                    .fill(MenuHighlightStyle.secondary(self.isHighlighted).opacity(0.22))
                    .frame(height: 1)
            }
        }
    }

    private var line: some View {
        GeometryReader { _ in
            Canvas { context, size in
                let scale = UsageChartScale(values: self.chart.points.map(\.value))
                let points = self.chart.points.enumerated().map { index, point in
                    let x = self.chart.points.count == 1
                        ? size.width / 2
                        : size.width * CGFloat(index) / CGFloat(self.chart.points.count - 1)
                    let y = size.height * (1 - CGFloat(scale.fraction(for: point.value)))
                    return CGPoint(x: x, y: y)
                }
                guard let first = points.first else { return }
                var path = Path()
                path.move(to: first)
                for point in points.dropFirst() {
                    path.addLine(to: point)
                }
                context.stroke(
                    path,
                    with: .color(self.isHighlighted ? .white.opacity(0.82) : self.color),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                for point in points {
                    context.fill(
                        Path(ellipseIn: CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3)),
                        with: .color(self.isHighlighted ? .white : self.color))
                }
            }
            .overlay(alignment: .bottomLeading) {
                Rectangle()
                    .fill(MenuHighlightStyle.secondary(self.isHighlighted).opacity(0.22))
                    .frame(height: 1)
            }
        }
    }

    private var accessibilityLabel: String {
        let title = self.chart.title.map { "\($0): " } ?? ""
        let unit = self.chart.unit.map { " \($0)" } ?? ""
        let points = self.chart.points.map { "\($0.label) \($0.value)\(unit)" }.joined(separator: ", ")
        return title + points
    }

    private func fillColor(value: Double, scale: UsageChartScale) -> Color {
        let ratio = max(0.18, scale.fraction(for: value))
        if self.isHighlighted {
            return Color.white.opacity(0.55 + ratio * 0.35)
        }
        return self.color.opacity(0.42 + ratio * 0.58)
    }

    private static func height(value: Double, scale: UsageChartScale, available: CGFloat) -> CGFloat {
        let ratio = scale.fraction(for: value)
        guard ratio > 0 else { return 1 }
        return max(3, CGFloat(ratio) * available)
    }
}
