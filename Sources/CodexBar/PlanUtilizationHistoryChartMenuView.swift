import Charts
import CodexBarCore
import SwiftUI

@MainActor
struct PlanUtilizationHistoryChartMenuView: View {
    private enum Layout {
        static let chartHeight: CGFloat = 130
        static let detailHeight: CGFloat = 32
        static let emptyStateHeight: CGFloat = chartHeight + detailHeight
    }

    private enum Period: String, CaseIterable, Identifiable {
        case daily
        case weekly
        case monthly

        var id: String {
            self.rawValue
        }

        var title: String {
            switch self {
            case .daily:
                "Daily"
            case .weekly:
                "Weekly"
            case .monthly:
                "Monthly"
            }
        }

        var emptyStateText: String {
            switch self {
            case .daily:
                "No daily utilization data yet."
            case .weekly:
                "No weekly utilization data yet."
            case .monthly:
                "No monthly utilization data yet."
            }
        }

        var maxPoints: Int {
            switch self {
            case .daily:
                30
            case .weekly:
                24
            case .monthly:
                24
            }
        }
    }

    private struct Point: Identifiable {
        let id: String
        let index: Int
        let date: Date
        let usedPercent: Double
    }

    private let provider: UsageProvider
    private let samples: [PlanUtilizationHistorySample]
    private let width: CGFloat

    @State private var selectedPeriod: Period = .daily
    @State private var selectedPointID: String?

    init(provider: UsageProvider, samples: [PlanUtilizationHistorySample], width: CGFloat) {
        self.provider = provider
        self.samples = samples
        self.width = width
    }

    var body: some View {
        let model = Self.makeModel(period: self.selectedPeriod, samples: self.samples, provider: self.provider)

        VStack(alignment: .leading, spacing: 10) {
            Picker("Period", selection: self.$selectedPeriod) {
                ForEach(Period.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: self.selectedPeriod) { _, _ in
                self.selectedPointID = nil
            }

            if model.points.isEmpty {
                ZStack {
                    Text(self.selectedPeriod.emptyStateText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: Layout.emptyStateHeight)
            } else {
                self.utilizationChart(model: model)
                    .chartYAxis(.hidden)
                    .chartYScale(domain: 0...100)
                    .chartXAxis {
                        AxisMarks(values: model.axisIndexes) { value in
                            AxisGridLine().foregroundStyle(Color.clear)
                            AxisTick().foregroundStyle(Color.clear)
                            AxisValueLabel {
                                if let raw = value.as(Double.self) {
                                    let index = Int(raw.rounded())
                                    if let point = model.pointsByIndex[index] {
                                        Text(point.date.formatted(self.axisFormat(for: self.selectedPeriod)))
                                            .font(.caption2)
                                            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                                    }
                                }
                            }
                        }
                    }
                    .chartLegend(.hidden)
                    .frame(height: Layout.chartHeight)
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            MouseLocationReader { location in
                                self.updateSelection(location: location, model: model, proxy: proxy, geo: geo)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                        }
                    }

                let detail = self.detailLines(model: model)
                VStack(alignment: .leading, spacing: 0) {
                    Text(detail.primary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: 16, alignment: .leading)
                    Text(detail.secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: 16, alignment: .leading)
                }
                .frame(height: Layout.detailHeight, alignment: .top)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minWidth: self.width, maxWidth: .infinity, alignment: .topLeading)
    }

    private struct Model {
        let points: [Point]
        let axisIndexes: [Double]
        let xDomain: ClosedRange<Double>?
        let pointsByID: [String: Point]
        let pointsByIndex: [Int: Point]
        let barColor: Color
    }

    private nonisolated static func makeModel(
        period: Period,
        samples: [PlanUtilizationHistorySample],
        provider: UsageProvider) -> Model
    {
        var buckets: [Date: Double] = [:]
        let calendar = Calendar.current

        let shouldDeriveCodexMonthlyFromWeekly = provider == .codex &&
            !samples.contains(where: { $0.monthlyUsedPercent != nil })
        let shouldDeriveMonthlyFromWeekly = period == .monthly &&
            (provider == .claude || shouldDeriveCodexMonthlyFromWeekly)

        if shouldDeriveMonthlyFromWeekly {
            // Subscription utilization is approximated from weekly windows when no suitable monthly source exists.
            // For Claude, this intentionally ignores pay-as-you-go extra usage spend.
            // Approximate monthly utilization as the average weekly used % observed in that month.
            var monthToWeekUsage: [Date: [Date: Double]] = [:]
            for sample in samples {
                guard let used = sample.weeklyUsedPercent else { continue }
                let clamped = max(0, min(100, used))
                guard
                    let monthDate = Self.bucketDate(for: sample.capturedAt, period: .monthly, calendar: calendar),
                    let weekDate = Self.bucketDate(for: sample.capturedAt, period: .weekly, calendar: calendar)
                else {
                    continue
                }
                var weekUsage = monthToWeekUsage[monthDate] ?? [:]
                weekUsage[weekDate] = max(weekUsage[weekDate] ?? 0, clamped)
                monthToWeekUsage[monthDate] = weekUsage
            }

            for (monthDate, weekUsage) in monthToWeekUsage {
                guard !weekUsage.isEmpty else { continue }
                let totalUsed = weekUsage.values.reduce(0, +)
                buckets[monthDate] = totalUsed / Double(weekUsage.count)
            }
        } else {
            for sample in samples {
                guard let used = Self.usedPercent(for: sample, period: period) else { continue }
                let clamped = max(0, min(100, used))
                guard
                    let bucketDate = Self.bucketDate(for: sample.capturedAt, period: period, calendar: calendar)
                else {
                    continue
                }
                let current = buckets[bucketDate] ?? 0
                buckets[bucketDate] = max(current, clamped)
            }
        }

        var points = buckets
            .map { date, used in
                Point(
                    id: Self.pointID(date: date, period: period),
                    index: 0,
                    date: date,
                    usedPercent: used)
            }
            .sorted { $0.date < $1.date }

        if points.count > period.maxPoints {
            points = Array(points.suffix(period.maxPoints))
        }

        points = points.enumerated().map { offset, point in
            Point(
                id: point.id,
                index: offset,
                date: point.date,
                usedPercent: point.usedPercent)
        }

        let axisIndexes = Self.axisIndexes(points: points, period: period)
        let xDomain = Self.xDomain(points: points, period: period)

        let pointsByID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })
        let pointsByIndex = Dictionary(uniqueKeysWithValues: points.map { ($0.index, $0) })
        let color = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
        let barColor = Color(red: color.red, green: color.green, blue: color.blue)

        return Model(
            points: points,
            axisIndexes: axisIndexes,
            xDomain: xDomain,
            pointsByID: pointsByID,
            pointsByIndex: pointsByIndex,
            barColor: barColor)
    }

    private nonisolated static func xDomain(points: [Point], period: Period) -> ClosedRange<Double>? {
        guard !points.isEmpty else { return nil }
        return -0.5...(Double(period.maxPoints) - 0.5)
    }

    private nonisolated static func axisIndexes(points: [Point], period: Period) -> [Double] {
        guard let first = points.first?.index, let last = points.last?.index else { return [] }
        if first == last { return [Double(first)] }
        switch period {
        case .daily:
            return [Double(first), Double(last)]
        case .weekly, .monthly:
            return [Double(last)]
        }
    }

    #if DEBUG
    struct ModelSnapshot: Equatable {
        let pointCount: Int
        let axisIndexes: [Double]
        let xDomain: ClosedRange<Double>?
    }

    nonisolated static func _modelSnapshotForTesting(
        periodRawValue: String,
        samples: [PlanUtilizationHistorySample],
        provider: UsageProvider) -> ModelSnapshot?
    {
        guard let period = Period(rawValue: periodRawValue) else { return nil }
        let model = self.makeModel(period: period, samples: samples, provider: provider)
        return ModelSnapshot(
            pointCount: model.points.count,
            axisIndexes: model.axisIndexes,
            xDomain: model.xDomain)
    }
    #endif

    private nonisolated static func usedPercent(for sample: PlanUtilizationHistorySample, period: Period) -> Double? {
        switch period {
        case .daily:
            sample.dailyUsedPercent
        case .weekly:
            sample.weeklyUsedPercent
        case .monthly:
            sample.monthlyUsedPercent
        }
    }

    private nonisolated static func bucketDate(for date: Date, period: Period, calendar: Calendar) -> Date? {
        switch period {
        case .daily:
            calendar.startOfDay(for: date)
        case .weekly:
            calendar.dateInterval(of: .weekOfYear, for: date)?.start
        case .monthly:
            calendar.dateInterval(of: .month, for: date)?.start
        }
    }

    private nonisolated static func pointID(date: Date, period: Period) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = switch period {
        case .daily:
            "yyyy-MM-dd"
        case .weekly:
            "yyyy-'W'ww"
        case .monthly:
            "yyyy-MM"
        }
        return formatter.string(from: date)
    }

    private func xValue(for index: Int) -> PlottableValue<Double> {
        .value("Period", Double(index))
    }

    @ViewBuilder
    private func utilizationChart(model: Model) -> some View {
        if let xDomain = model.xDomain {
            Chart {
                self.utilizationChartContent(model: model)
            }
            .chartXScale(domain: xDomain)
        } else {
            Chart {
                self.utilizationChartContent(model: model)
            }
        }
    }

    @ChartContentBuilder
    private func utilizationChartContent(model: Model) -> some ChartContent {
        ForEach(model.points) { point in
            BarMark(
                x: self.xValue(for: point.index),
                y: .value("Utilization", point.usedPercent))
                .foregroundStyle(model.barColor)
        }
        if let selected = self.selectedPoint(model: model) {
            RuleMark(x: self.xValue(for: selected.index))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    private func axisFormat(for period: Period) -> Date.FormatStyle {
        switch period {
        case .daily, .weekly:
            .dateTime.month(.abbreviated).day()
        case .monthly:
            .dateTime.month(.abbreviated).year(.defaultDigits)
        }
    }

    private func selectedPoint(model: Model) -> Point? {
        guard let selectedPointID else { return nil }
        return model.pointsByID[selectedPointID]
    }

    private func detailLines(model: Model) -> (primary: String, secondary: String) {
        let activePoint = self.selectedPoint(model: model) ?? model.points.last
        guard let point = activePoint else {
            return ("No data", "")
        }

        let dateLabel: String = switch self.selectedPeriod {
        case .daily, .weekly:
            point.date.formatted(.dateTime.month(.abbreviated).day())
        case .monthly:
            point.date.formatted(.dateTime.month(.abbreviated).year(.defaultDigits))
        }

        let used = max(0, min(100, point.usedPercent))
        let wasted = max(0, 100 - used)
        let usedText = used.formatted(.number.precision(.fractionLength(0...1)))
        let wastedText = wasted.formatted(.number.precision(.fractionLength(0...1)))

        return (
            "\(dateLabel): \(usedText)% used",
            "\(wastedText)% wasted")
    }

    private func updateSelection(
        location: CGPoint?,
        model: Model,
        proxy: ChartProxy,
        geo: GeometryProxy)
    {
        guard let location else {
            if self.selectedPointID != nil { self.selectedPointID = nil }
            return
        }

        guard let plotAnchor = proxy.plotFrame else { return }
        let plotFrame = geo[plotAnchor]
        guard plotFrame.contains(location) else {
            if self.selectedPointID != nil { self.selectedPointID = nil }
            return
        }

        let xInPlot = location.x - plotFrame.origin.x
        guard let xValue: Double = proxy.value(atX: xInPlot) else { return }

        var best: (id: String, distance: Double)?
        for point in model.points {
            let distance = abs(Double(point.index) - xValue)
            if let current = best {
                if distance < current.distance {
                    best = (point.id, distance)
                }
            } else {
                best = (point.id, distance)
            }
        }

        if self.selectedPointID != best?.id {
            self.selectedPointID = best?.id
        }
    }
}
