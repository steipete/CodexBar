import CodexBarCore
import SwiftUI

@MainActor
struct ZaiHourlyUsageChartMenuView: View {
    private let modelUsage: ZaiModelUsageData
    private let dailyModelUsage: ZaiModelUsageData?
    private let width: CGFloat

    @State private var selectedRange: RangeOption = .today
    @State private var isExpanded = true
    @State private var hoveredBarIndex: Int?

    enum RangeOption: Int, CaseIterable {
        case today = 0
        case last24h = 1
        case last7d = 2
        case last30d = 3

        func range(referenceDate: Date) -> ZaiHourlyRange {
            switch self {
            case .today: .today(referenceDate: referenceDate)
            case .last24h: .last24h
            case .last7d: .last7d
            case .last30d: .last30d
            }
        }
    }

    struct RenderState {
        let bars: [ZaiHourlyBar]
        let modelNames: [String]
        let isDaily: Bool

        static func make(
            modelUsage: ZaiModelUsageData,
            dailyModelUsage: ZaiModelUsageData?,
            selectedRange: RangeOption,
            now: Date) -> RenderState
        {
            let range = selectedRange.range(referenceDate: now)
            let selectedData = range.isDaily ? (dailyModelUsage ?? modelUsage) : modelUsage
            return RenderState(
                bars: ZaiHourlyBars.from(modelData: selectedData, range: range, now: now),
                modelNames: selectedData.modelNames,
                isDaily: range.isDaily)
        }

        func tooltipTitle(for bar: ZaiHourlyBar) -> String {
            self.isDaily ? bar.label : "\(bar.label):00"
        }

        func colorIndex(for modelName: String, paletteCount: Int) -> Int {
            guard paletteCount > 0 else { return 0 }
            return (self.modelNames.firstIndex(of: modelName) ?? 0) % paletteCount
        }
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

    init(modelUsage: ZaiModelUsageData, dailyModelUsage: ZaiModelUsageData?, width: CGFloat) {
        self.modelUsage = modelUsage
        self.dailyModelUsage = dailyModelUsage
        self.width = width
    }

    private var renderState: RenderState {
        RenderState.make(
            modelUsage: self.modelUsage,
            dailyModelUsage: self.dailyModelUsage,
            selectedRange: self.selectedRange,
            now: Date())
    }

    var body: some View {
        let renderState = self.renderState
        let bars = renderState.bars

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

                Text(L("Hourly Tokens"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)

                Spacer()

                if self.isExpanded {
                    self.rangeToggle
                }
            }

            if self.isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    if bars.isEmpty {
                        Text(L("No data"))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 16)
                    } else {
                        GeometryReader { geometry in
                            let barWidth = max(
                                (geometry.size.width - self.barGap * CGFloat(max(bars.count - 1, 0)))
                                    / CGFloat(bars.count),
                                2)
                            HStack(alignment: .bottom, spacing: self.barGap) {
                                ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                                    VStack(spacing: 0) {
                                        Spacer(minLength: 0)
                                        self.barStack(
                                            bar: bar,
                                            barWidth: barWidth,
                                            maxTotal: self.maxTotal(in: bars),
                                            renderState: renderState)
                                    }
                                    .frame(width: barWidth, height: self.barHeight)
                                    .contentShape(Rectangle())
                                    .onHover { hovering in
                                        self.hoveredBarIndex = hovering ? index : nil
                                    }
                                    .overlay(alignment: .bottom) {
                                        if self.hoveredBarIndex == index {
                                            self.tooltipOverlay(bar: bar, renderState: renderState)
                                        }
                                    }
                                }
                            }
                            .frame(height: self.barHeight)
                        }
                        .frame(height: self.barHeight)

                        self.legend(renderState: renderState)
                        self.xAxisLabels(bars: bars)
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

    private func maxTotal(in bars: [ZaiHourlyBar]) -> Int {
        bars.map(\.totalTokens).max() ?? 1
    }

    private var rangeToggle: some View {
        Picker("", selection: Binding(
            get: { self.selectedRange.rawValue },
            set: { self.selectedRange = RangeOption(rawValue: $0) ?? .today }))
        {
            Text(L("Today")).tag(RangeOption.today.rawValue)
            Text("24h").tag(RangeOption.last24h.rawValue)
            Text("7d").tag(RangeOption.last7d.rawValue)
            Text("30d").tag(RangeOption.last30d.rawValue)
        }
        .pickerStyle(.segmented)
        .frame(width: 100)
        .scaleEffect(0.8)
        .frame(width: 80, height: 16)
    }

    @ViewBuilder
    private func barStack(
        bar: ZaiHourlyBar,
        barWidth: CGFloat,
        maxTotal: Int,
        renderState: RenderState) -> some View
    {
        let scaleFactor = CGFloat(bar.totalTokens) / CGFloat(max(maxTotal, 1))

        VStack(spacing: 0) {
            ForEach(Array(bar.segments.enumerated()), id: \.offset) { segIndex, segment in
                let segFraction = CGFloat(segment.tokens) / CGFloat(max(bar.totalTokens, 1))
                let segHeight = max(
                    self.barHeight * scaleFactor * segFraction,
                    segment.tokens > 0 ? 1 : 0)
                RoundedRectangle(cornerRadius: segIndex == bar.segments.count - 1 ? 2 : 0)
                    .fill(self.colorForModel(segment.model, renderState: renderState))
                    .frame(height: segHeight)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    private func tooltipOverlay(bar: ZaiHourlyBar, renderState: RenderState) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(renderState.tooltipTitle(for: bar))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.primary)
            ForEach(Array(bar.segments.enumerated()), id: \.offset) { _, segment in
                HStack(spacing: 3) {
                    Circle()
                        .fill(self.colorForModel(segment.model, renderState: renderState))
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

    private func legend(renderState: RenderState) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(renderState.modelNames, id: \.self) { name in
                    HStack(spacing: 2) {
                        Circle()
                            .fill(self.colorForModel(name, renderState: renderState))
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

    private func xAxisLabels(bars: [ZaiHourlyBar]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(self.labelIndices(for: bars).enumerated()), id: \.offset) { _, index in
                if index < bars.count {
                    Text(bars[index].label)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func labelIndices(for bars: [ZaiHourlyBar]) -> [Int] {
        guard bars.count > self.maxLabelCount else { return Array(0..<bars.count) }
        let step = max(1, bars.count / (self.maxLabelCount - 1))
        var indices = stride(from: 0, to: bars.count, by: step).map(\.self)
        if indices.last != bars.count - 1 {
            indices.append(bars.count - 1)
        }
        return indices
    }

    private func colorForModel(_ name: String, renderState: RenderState) -> Color {
        let index = renderState.colorIndex(for: name, paletteCount: self.colorPalette.count)
        return self.colorPalette[index]
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
