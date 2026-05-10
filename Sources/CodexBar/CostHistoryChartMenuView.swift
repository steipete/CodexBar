import Charts
import CodexBarCore
import SwiftUI

@MainActor
struct CostHistoryChartMenuView: View {
    typealias DailyEntry = CostUsageDailyReport.Entry

    private struct Point: Identifiable {
        let id: String
        let date: Date
        let costUSD: Double
        let totalTokens: Int?

        init(date: Date, costUSD: Double, totalTokens: Int?) {
            self.date = date
            self.costUSD = costUSD
            self.totalTokens = totalTokens
            self.id = "\(Int(date.timeIntervalSince1970))-\(costUSD)"
        }
    }

    private struct DetailRow: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let accentColor: Color
    }

    private struct DetailContent {
        let primary: String
        let rows: [DetailRow]
    }

    private let provider: UsageProvider
    private let daily: [DailyEntry]
    private let totalCostUSD: Double?
    private let width: CGFloat
    @State private var selectedDateKey: String?

    init(provider: UsageProvider, daily: [DailyEntry], totalCostUSD: Double?, width: CGFloat) {
        self.provider = provider
        self.daily = daily
        self.totalCostUSD = totalCostUSD
        self.width = width
    }

    var body: some View {
        let model = Self.makeModel(provider: self.provider, daily: self.daily)
        VStack(alignment: .leading, spacing: 10) {
            if model.points.isEmpty {
                Text("No cost history data.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("No cost history data available.")
            } else {
                Chart {
                    ForEach(model.points) { point in
                        BarMark(
                            x: .value("Day", point.date, unit: .day),
                            y: .value("Cost", point.costUSD))
                            .foregroundStyle(model.barColor)
                    }
                    if let peak = Self.peakPoint(model: model) {
                        let capStart = max(peak.costUSD - Self.capHeight(maxValue: model.maxCostUSD), 0)
                        BarMark(
                            x: .value("Day", peak.date, unit: .day),
                            yStart: .value("Cap start", capStart),
                            yEnd: .value("Cap end", peak.costUSD))
                            .foregroundStyle(Color(nsColor: .systemYellow))
                    }
                }
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: model.axisDates) { _ in
                        AxisGridLine().foregroundStyle(Color.clear)
                        AxisTick().foregroundStyle(Color.clear)
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .font(.caption2)
                            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 130)
                .accessibilityLabel("Cost history chart")
                .accessibilityValue(model.points.isEmpty ? "No data" : "\(model.points.count) days of cost data")
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            if let rect = self.selectionBandRect(model: model, proxy: proxy, geo: geo) {
                                Rectangle()
                                    .fill(Self.selectionBandColor)
                                    .frame(width: rect.width, height: rect.height)
                                    .position(x: rect.midX, y: rect.midY)
                                    .allowsHitTesting(false)
                            }
                            MouseLocationReader { location in
                                self.updateSelection(location: location, model: model, proxy: proxy, geo: geo)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                        }
                    }
                }

                let detail = self.detailContent(model: model)
                VStack(alignment: .leading, spacing: Self.detailSpacing) {
                    Text(detail.primary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: Self.detailPrimaryLineHeight, alignment: .leading)
                    ForEach(detail.rows) { row in
                        HStack(alignment: .top, spacing: 8) {
                            Rectangle()
                                .fill(row.accentColor)
                                .frame(width: 2, height: row.subtitle == nil ? 14 : Self.detailRowHeight)
                                .padding(.top, 1)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                if let subtitle = row.subtitle {
                                    Text(subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                        }
                        .frame(height: Self.detailRowHeight, alignment: .leading)
                    }
                    ForEach(0..<max(model.maxRenderedBreakdownRows - detail.rows.count, 0), id: \.self) { _ in
                        Text(" ")
                            .font(.caption)
                            .frame(height: Self.detailRowHeight, alignment: .leading)
                            .opacity(0)
                    }
                }
                .frame(
                    height: Self.detailBlockHeight(maxBreakdownRows: model.maxRenderedBreakdownRows),
                    alignment: .topLeading)
            }

            if let total = self.totalCostUSD {
                Text("Total (30d): \(UsageFormatter.usdString(total))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minWidth: self.width, maxWidth: .infinity, alignment: .leading)
    }

    private struct Model {
        let points: [Point]
        let pointsByDateKey: [String: Point]
        let entriesByDateKey: [String: DailyEntry]
        let dateKeys: [(key: String, date: Date)]
        let axisDates: [Date]
        let barColor: Color
        let peakKey: String?
        let maxCostUSD: Double
        let maxRenderedBreakdownRows: Int
    }

    private static let selectionBandColor = Color(nsColor: .labelColor).opacity(0.1)
    private static let maxVisibleDetailLines = 4
    private static let detailPrimaryLineHeight: CGFloat = 16
    private static let detailRowHeight: CGFloat = 24
    private static let detailSpacing: CGFloat = 6

    private static func capHeight(maxValue: Double) -> Double {
        maxValue * 0.05
    }

    private static func makeModel(provider: UsageProvider, daily: [DailyEntry]) -> Model {
        let sorted = daily.sorted { lhs, rhs in lhs.date < rhs.date }
        var points: [Point] = []
        points.reserveCapacity(sorted.count)

        var pointsByKey: [String: Point] = [:]
        pointsByKey.reserveCapacity(sorted.count)

        var entriesByKey: [String: DailyEntry] = [:]
        entriesByKey.reserveCapacity(sorted.count)

        var dateKeys: [(key: String, date: Date)] = []
        dateKeys.reserveCapacity(sorted.count)

        var peak: (key: String, costUSD: Double)?
        var maxCostUSD: Double = 0
        var maxRenderedBreakdownRows = 0
        for entry in sorted {
            guard let costUSD = entry.costUSD, costUSD >= 0 else { continue }
            guard let date = self.dateFromDayKey(entry.date) else { continue }
            let point = Point(date: date, costUSD: costUSD, totalTokens: entry.totalTokens)
            points.append(point)
            pointsByKey[entry.date] = point
            entriesByKey[entry.date] = entry
            dateKeys.append((entry.date, date))
            maxRenderedBreakdownRows = max(maxRenderedBreakdownRows, Self.renderedBreakdownRowCount(for: entry))
            if let cur = peak {
                if costUSD > cur.costUSD { peak = (entry.date, costUSD) }
            } else {
                peak = (entry.date, costUSD)
            }
            maxCostUSD = max(maxCostUSD, costUSD)
        }

        let axisDates: [Date] = {
            guard let first = dateKeys.first?.date, let last = dateKeys.last?.date else { return [] }
            if Calendar.current.isDate(first, inSameDayAs: last) { return [first] }
            return [first, last]
        }()

        let barColor = Self.barColor(for: provider)
        return Model(
            points: points,
            pointsByDateKey: pointsByKey,
            entriesByDateKey: entriesByKey,
            dateKeys: dateKeys,
            axisDates: axisDates,
            barColor: barColor,
            peakKey: maxCostUSD > 0 ? peak?.key : nil,
            maxCostUSD: maxCostUSD,
            maxRenderedBreakdownRows: maxRenderedBreakdownRows)
    }

    private static func barColor(for provider: UsageProvider) -> Color {
        let color = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
        return Color(red: color.red, green: color.green, blue: color.blue)
    }

    private static func dateFromDayKey(_ key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }

        var comps = DateComponents()
        comps.calendar = Calendar.current
        comps.timeZone = TimeZone.current
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        return comps.date
    }

    private static func peakPoint(model: Model) -> Point? {
        guard let key = model.peakKey else { return nil }
        return model.pointsByDateKey[key]
    }

    private static func renderedBreakdownRowCount(for entry: DailyEntry) -> Int {
        guard let breakdown = entry.modelBreakdowns, !breakdown.isEmpty else { return 0 }
        return min(breakdown.count, self.maxVisibleDetailLines)
    }

    private static func detailBlockHeight(maxBreakdownRows: Int) -> CGFloat {
        guard maxBreakdownRows > 0 else { return self.detailPrimaryLineHeight }
        return self.detailPrimaryLineHeight +
            (CGFloat(maxBreakdownRows) * self.detailRowHeight) +
            (CGFloat(maxBreakdownRows) * self.detailSpacing)
    }

    private func selectionBandRect(model: Model, proxy: ChartProxy, geo: GeometryProxy) -> CGRect? {
        guard let key = self.selectedDateKey else { return nil }
        guard let plotAnchor = proxy.plotFrame else { return nil }
        let plotFrame = geo[plotAnchor]
        guard let index = model.dateKeys.firstIndex(where: { $0.key == key }) else { return nil }
        let date = model.dateKeys[index].date
        guard let x = proxy.position(forX: date) else { return nil }

        func xForIndex(_ idx: Int) -> CGFloat? {
            guard idx >= 0, idx < model.dateKeys.count else { return nil }
            return proxy.position(forX: model.dateKeys[idx].date)
        }

        let xPrev = xForIndex(index - 1)
        let xNext = xForIndex(index + 1)

        let leftInPlot: CGFloat = if let xPrev {
            (xPrev + x) / 2
        } else if let xNext {
            x - (xNext - x) / 2
        } else {
            x - 8
        }

        let rightInPlot: CGFloat = if let xNext {
            (xNext + x) / 2
        } else if let xPrev {
            x + (x - xPrev) / 2
        } else {
            x + 8
        }

        let left = plotFrame.origin.x + min(leftInPlot, rightInPlot)
        let right = plotFrame.origin.x + max(leftInPlot, rightInPlot)
        return CGRect(x: left, y: plotFrame.origin.y, width: right - left, height: plotFrame.height)
    }

    private func updateSelection(
        location: CGPoint?,
        model: Model,
        proxy: ChartProxy,
        geo: GeometryProxy)
    {
        guard let location else {
            if self.selectedDateKey != nil { self.selectedDateKey = nil }
            return
        }

        guard let plotAnchor = proxy.plotFrame else { return }
        let plotFrame = geo[plotAnchor]
        guard plotFrame.contains(location) else { return }

        let xInPlot = location.x - plotFrame.origin.x
        guard let date: Date = proxy.value(atX: xInPlot) else { return }
        guard let nearest = self.nearestDateKey(to: date, model: model) else { return }

        if self.selectedDateKey != nearest {
            self.selectedDateKey = nearest
        }
    }

    private func nearestDateKey(to date: Date, model: Model) -> String? {
        guard !model.dateKeys.isEmpty else { return nil }
        var best: (key: String, distance: TimeInterval)?
        for entry in model.dateKeys {
            let dist = abs(entry.date.timeIntervalSince(date))
            if let cur = best {
                if dist < cur.distance { best = (entry.key, dist) }
            } else {
                best = (entry.key, dist)
            }
        }
        return best?.key
    }

    private func detailContent(model: Model) -> DetailContent {
        guard let key = self.selectedDateKey,
              let point = model.pointsByDateKey[key],
              let date = Self.dateFromDayKey(key)
        else {
            return DetailContent(primary: "Hover a bar for details", rows: [])
        }

        let dayLabel = date.formatted(.dateTime.month(.abbreviated).day())
        let cost = UsageFormatter.usdString(point.costUSD)
        let primary = if let tokens = point.totalTokens {
            "\(dayLabel): \(cost) · \(UsageFormatter.tokenCountString(tokens)) tokens"
        } else {
            "\(dayLabel): \(cost)"
        }
        return DetailContent(primary: primary, rows: self.breakdownRows(key: key, model: model))
    }

    private func breakdownRows(key: String, model: Model) -> [DetailRow] {
        guard let entry = model.entriesByDateKey[key] else { return [] }
        guard let breakdown = entry.modelBreakdowns, !breakdown.isEmpty else { return [] }

        return breakdown
            .sorted { lhs, rhs in
                let lCost = lhs.costUSD ?? -1
                let rCost = rhs.costUSD ?? -1
                if lCost != rCost { return lCost > rCost }

                let lTokens = lhs.totalTokens ?? -1
                let rTokens = rhs.totalTokens ?? -1
                if lTokens != rTokens { return lTokens > rTokens }

                return lhs.modelName > rhs.modelName
            }
            .prefix(Self.maxVisibleDetailLines)
            .enumerated()
            .map { index, item in
                DetailRow(
                    id: "\(item.modelName)-\(index)",
                    title: UsageFormatter.modelDisplayName(item.modelName),
                    subtitle: UsageFormatter.modelCostDetail(
                        item.modelName,
                        costUSD: item.costUSD,
                        totalTokens: item.totalTokens),
                    accentColor: model.barColor.opacity(Self.breakdownAccentOpacity(for: index)))
            }
    }

    private static func breakdownAccentOpacity(for index: Int) -> Double {
        let opacity = 0.75 - (Double(index) * 0.12)
        return max(0.3, opacity)
    }
}
