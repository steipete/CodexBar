import CodexBarCore
import SwiftUI

@MainActor
struct ZaiHourlyUsageChartMenuView: View {
    private let modelUsage: ZaiModelUsageData
    private let width: CGFloat

    @State private var selectedRange: RangeOption = .today
    @State private var isExpanded = true
    @State private var hoveredBarIndex: Int?

    private enum RangeOption: Int, CaseIterable {
        case today = 0
        case last24h = 1
    }

    private let barHeight: CGFloat = 60
    private let barGap: CGFloat = 2
    private let maxLabelCount = 5

    private let colorPalette: [Color] = [
        Color(red: 10 / 255, green: 132 / 255, blue: 1),
        Color(red: 255 / 255, green: 159 / 255, blue: 10 / 255),
        Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255),
        Color(red: 94 / 255, green: 92 / 255, blue: 230 / 255),
        Color(red: 100 / 255, green: 210 / 255, blue: 255 / 255),
        Color(red: 255 / 255, green: 55 / 255, blue: 95 / 255),
    ]

    init(modelUsage: ZaiModelUsageData, width: CGFloat) {
        self.modelUsage = modelUsage
        self.width = width
    }

    private var range: ZaiHourlyRange {
        switch self.selectedRange {
        case .today: .today(referenceDate: Date())
        case .last24h: .last24h
        }
    }

    private var bars: [ZaiHourlyBar] {
        ZaiHourlyBars.from(modelData: self.modelUsage, range: self.range)
    }

    private var modelNames: [String] {
        self.modelUsage.modelNames
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button(
                    action: { withAnimation(.easeInOut(duration: 0.2)) { self.isExpanded.toggle() } },
                    label: {
                        Image(systemName: self.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                            .frame(width: 10)
                    })
                    .buttonStyle(.plain)

                Text("Hourly Tokens")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)

                Spacer()

                if self.isExpanded {
                    self.rangeToggle
                }
            }

            if self.isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    if self.bars.isEmpty {
                        Text("No data")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 16)
                    } else {
                        GeometryReader { geometry in
                            let barWidth = max(
                                (geometry.size.width - self.barGap * CGFloat(max(self.bars.count - 1, 0)))
                                    / CGFloat(self.bars.count),
                                2)
                            HStack(alignment: .bottom, spacing: self.barGap) {
                                ForEach(Array(self.bars.enumerated()), id: \.offset) { index, bar in
                                    VStack(spacing: 0) {
                                        Spacer(minLength: 0)
                                        self.barStack(bar: bar, barWidth: barWidth, maxTotal: self.maxTotal)
                                    }
                                    .frame(width: barWidth, height: self.barHeight)
                                    .contentShape(Rectangle())
                                    .onHover { hovering in
                                        self.hoveredBarIndex = hovering ? index : nil
                                    }
                                    .overlay(alignment: .bottom) {
                                        if self.hoveredBarIndex == index {
                                            self.tooltipOverlay(bar: bar)
                                        }
                                    }
                                }
                            }
                            .frame(height: self.barHeight)
                        }
                        .frame(height: self.barHeight)

                        self.legend
                        self.xAxisLabels
                    }
                }
                .padding(.top, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minWidth: self.width, maxWidth: .infinity, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.2), value: self.isExpanded)
    }

    private var maxTotal: Int {
        self.bars.map(\.totalTokens).max() ?? 1
    }

    private var rangeToggle: some View {
        Picker("", selection: Binding(
            get: { self.selectedRange.rawValue },
            set: { self.selectedRange = RangeOption(rawValue: $0) ?? .today }))
        {
            Text("Today").tag(RangeOption.today.rawValue)
            Text("24h").tag(RangeOption.last24h.rawValue)
        }
        .pickerStyle(.segmented)
        .frame(width: 100)
        .scaleEffect(0.8)
        .frame(width: 80, height: 16)
    }

    @ViewBuilder
    private func barStack(bar: ZaiHourlyBar, barWidth: CGFloat, maxTotal: Int) -> some View {
        let scaleFactor = CGFloat(bar.totalTokens) / CGFloat(max(maxTotal, 1))

        VStack(spacing: 0) {
            ForEach(Array(bar.segments.enumerated()), id: \.offset) { segIndex, segment in
                let segFraction = CGFloat(segment.tokens) / CGFloat(max(bar.totalTokens, 1))
                let segHeight = max(
                    self.barHeight * scaleFactor * segFraction,
                    segment.tokens > 0 ? 1 : 0)
                RoundedRectangle(cornerRadius: segIndex == bar.segments.count - 1 ? 2 : 0)
                    .fill(self.colorForModel(segment.model))
                    .frame(height: segHeight)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    private func tooltipOverlay(bar: ZaiHourlyBar) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(bar.label + ":00")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.primary)
            ForEach(Array(bar.segments.enumerated()), id: \.offset) { _, segment in
                HStack(spacing: 3) {
                    Circle()
                        .fill(self.colorForModel(segment.model))
                        .frame(width: 5, height: 5)
                    Text(segment.model)
                        .font(.system(size: 9))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(self.formatTokenCount(segment.tokens))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.primary)
                }
            }
            Divider()
                .background(Color.primary.opacity(0.15))
            Text(self.formatTokenCount(bar.totalTokens))
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.primary)
        }
        .padding(6)
        .frame(minWidth: 90, maxWidth: 140)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.95))
        .background(.ultraThinMaterial)
        .cornerRadius(6)
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        .offset(y: -self.barHeight - 8)
    }

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(self.modelNames, id: \.self) { name in
                    HStack(spacing: 2) {
                        Circle()
                            .fill(self.colorForModel(name))
                            .frame(width: 6, height: 6)
                        Text(name)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var xAxisLabels: some View {
        HStack(spacing: 0) {
            ForEach(Array(self.labelIndices.enumerated()), id: \.offset) { _, index in
                if index < self.bars.count {
                    Text(self.bars[index].label)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var labelIndices: [Int] {
        guard self.bars.count > self.maxLabelCount else { return Array(0..<self.bars.count) }
        let step = max(1, self.bars.count / (self.maxLabelCount - 1))
        var indices = stride(from: 0, to: self.bars.count, by: step).map(\.self)
        if indices.last != self.bars.count - 1 {
            indices.append(self.bars.count - 1)
        }
        return indices
    }

    private func colorForModel(_ name: String) -> Color {
        let index = self.modelNames.firstIndex(of: name) ?? 0
        return self.colorPalette[index % self.colorPalette.count]
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1000 {
            String(format: "%.1fk", Double(count) / 1000)
        } else {
            "\(count)"
        }
    }
}
