import Charts
import CodexBarCore
import SwiftUI

enum SpendModelMetric: String, CaseIterable, Identifiable {
    case tokens
    case estimatedSpend

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .tokens: "Tokens"
        case .estimatedSpend: "Estimated spend"
        }
    }
}

func spendModelsDayRangeText(_ days: Int) -> String {
    switch days {
    case 7: "7d"
    case 30: "30d"
    case 365: "All"
    default: "\(days)d"
    }
}

enum SpendModelsEnglishFormatter {
    static func dayText(_ day: Date) -> String {
        day.formatted(.dateTime.month(.abbreviated).day().locale(self.locale))
    }

    private static let locale = Locale(identifier: "en_US_POSIX")
}

func spendModelsRowDetailText(_ row: SpendModelsPresentation.Row) -> String {
    guard let value = row.value else { return "—" }
    let providers = row.source.providerNames.joined(separator: " · ")
    let metric: String = if row.source.inputTokens != nil,
                            row.source.outputTokens != nil,
                            let inputTokens = row.source.inputTokens,
                            let outputTokens = row.source.outputTokens
    {
        "\(UsageFormatter.tokenCountString(inputTokens)) in · \(UsageFormatter.tokenCountString(outputTokens)) out"
    } else {
        UsageFormatter.tokenCountString(Int(value.rounded()))
    }
    return providers.isEmpty ? metric : "\(metric) · \(providers)"
}

struct SpendModelsPresentation: Equatable {
    struct Row: Identifiable, Equatable {
        let source: SpendDashboardModel.ModelAnalysisRow
        let rank: Int
        let value: Double?
        let share: Double?

        var id: String {
            self.source.id
        }
    }

    struct Series: Identifiable, Equatable {
        let id: String
        let name: String
        let value: Double
    }

    struct Point: Identifiable, Equatable {
        let day: Date
        let seriesID: String
        let seriesName: String
        let value: Double
        let stackStart: Double
        let stackEnd: Double

        var id: String {
            "\(self.seriesID):\(Int(self.day.timeIntervalSince1970))"
        }
    }

    let metric: SpendModelMetric
    let rows: [Row]
    let series: [Series]
    let points: [Point]
    let coverage: SpendDashboardModel.ModelMetricCoverage
    let metricTotal: Double?

    init(
        analysis: SpendDashboardModel.ModelAnalysis,
        metric: SpendModelMetric)
    {
        self.metric = metric
        self.coverage = switch metric {
        case .tokens: analysis.tokenCoverage
        case .estimatedSpend: analysis.costCoverage
        }

        let sortedSources = analysis.rows.sorted { lhs, rhs in
            Self.compare(lhs, rhs, metric: metric)
        }
        let metricValues = sortedSources.compactMap { Self.value($0, metric: metric) }
        let metricTotal = Self.sum(metricValues)
        self.metricTotal = metricTotal
        self.rows = sortedSources.enumerated().map { offset, source in
            let value = Self.value(source, metric: metric)
            return Row(
                source: source,
                rank: offset + 1,
                value: value,
                share: value.flatMap { value in
                    guard let total = metricTotal, total > 0 else { return nil }
                    return value / total
                })
        }

        let builtSeries = self.rows.compactMap { row -> Series? in
            guard let value = row.value else { return nil }
            guard value > 0 else { return nil }
            return Series(id: row.id, name: row.source.displayName, value: value)
        }
        self.series = builtSeries

        let valuesByDay = Dictionary(grouping: analysis.dailyValues, by: \.day)
        self.points = valuesByDay.keys.sorted().flatMap { day in
            let dailyValues = valuesByDay[day] ?? []
            var seriesValues: [String: Double] = [:]
            for dailyValue in dailyValues {
                guard let value = Self.value(dailyValue, metric: metric), value > 0 else { continue }
                seriesValues[dailyValue.modelID, default: 0] += value
            }
            var cursor = 0.0
            return builtSeries.compactMap { series -> Point? in
                guard let value = seriesValues[series.id], value > 0 else { return nil }
                let start = cursor
                cursor += value
                return Point(
                    day: day,
                    seriesID: series.id,
                    seriesName: series.name,
                    value: value,
                    stackStart: start,
                    stackEnd: cursor)
            }
        }
    }

    private static func compare(
        _ lhs: SpendDashboardModel.ModelAnalysisRow,
        _ rhs: SpendDashboardModel.ModelAnalysisRow,
        metric: SpendModelMetric) -> Bool
    {
        switch (self.value(lhs, metric: metric), self.value(rhs, metric: metric)) {
        case let (left?, right?) where left != right: return left > right
        case (_?, nil): return true
        case (nil, _?): return false
        default:
            let otherMetric: SpendModelMetric = metric == .tokens ? .estimatedSpend : .tokens
            switch (self.value(lhs, metric: otherMetric), self.value(rhs, metric: otherMetric)) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.id < rhs.id
            }
        }
    }

    private static func value(
        _ row: SpendDashboardModel.ModelAnalysisRow,
        metric: SpendModelMetric) -> Double?
    {
        switch metric {
        case .tokens: row.totalTokens.map(Double.init)
        case .estimatedSpend: row.estimatedCost
        }
    }

    private static func value(
        _ value: SpendDashboardModel.ModelDailyValue,
        metric: SpendModelMetric) -> Double?
    {
        switch metric {
        case .tokens: value.totalTokens.map(Double.init)
        case .estimatedSpend: value.estimatedCost
        }
    }

    private static func sum(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let result = values.reduce(0, +)
        return result.isFinite ? result : nil
    }
}

struct SpendModelsAxisDates {
    static func make(
        selectedDays: Int,
        dataDays: [Date],
        domain: ClosedRange<Date>,
        calendar: Calendar = .current) -> [Date]
    {
        let normalizedDataDays = Array(Set(dataDays.map { calendar.startOfDay(for: $0) })).sorted()
        if selectedDays == 7 {
            return normalizedDataDays
        }

        let domainStart = calendar.startOfDay(for: domain.lowerBound)
        if selectedDays != 365 {
            return self.strideDates(
                from: domainStart,
                whileBefore: domain.upperBound,
                step: 7,
                calendar: calendar)
        }

        let dataEnd = normalizedDataDays.last
            ?? calendar.date(byAdding: .day, value: -1, to: domain.upperBound)
            ?? domainStart
        let daySpan = max(
            0,
            calendar.dateComponents([.day], from: domainStart, to: dataEnd).day ?? 0)
        guard daySpan > 0 else { return [domainStart] }

        // Keep the complete daily series, but limit All to roughly six readable date labels.
        let step = max(14, Int(ceil(Double(daySpan) / 5)))
        var dates = self.strideDates(
            from: domainStart,
            through: dataEnd,
            step: step,
            calendar: calendar)

        guard let last = dates.last,
              !calendar.isDate(last, inSameDayAs: dataEnd)
        else {
            return dates
        }

        let trailingGap = calendar.dateComponents([.day], from: last, to: dataEnd).day ?? step
        if trailingGap < max(7, step / 2), dates.count > 1 {
            dates[dates.count - 1] = dataEnd
        } else {
            dates.append(dataEnd)
        }
        return dates
    }

    private static func strideDates(
        from start: Date,
        whileBefore end: Date,
        step: Int,
        calendar: Calendar) -> [Date]
    {
        var dates: [Date] = []
        var cursor = start
        while cursor < end {
            dates.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: step, to: cursor) else { break }
            cursor = next
        }
        return dates
    }

    private static func strideDates(
        from start: Date,
        through end: Date,
        step: Int,
        calendar: Calendar) -> [Date]
    {
        var dates: [Date] = []
        var cursor = start
        while cursor <= end {
            dates.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: step, to: cursor) else { break }
            cursor = next
        }
        return dates
    }
}

struct SpendModelsSection: View {
    let analysis: SpendDashboardModel.ModelAnalysis
    let chartDomain: ClosedRange<Date>?
    @Binding var selectedDays: Int
    @State private var selectedDay: Date?

    private var presentation: SpendModelsPresentation {
        SpendModelsPresentation(analysis: self.analysis, metric: .tokens)
    }

    var body: some View {
        SpendDashboardPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(L("Models"))
                        .font(.headline)
                    Spacer()
                    ForEach([7, 30, 365], id: \.self) { days in
                        self.rangeButton(days)
                    }
                }
                if self.presentation.points.isEmpty {
                    Text(L("No model-level history"))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                } else {
                    self.chart
                    self.ranking
                }
                if self.presentation.coverage == .partial {
                    Text(L("Partial model history: incomplete source-days are excluded."))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(self.presentation.points) { point in
                BarMark(
                    x: .value("Day", point.day, unit: .day),
                    yStart: .value("Tokens", point.stackStart),
                    yEnd: .value("Tokens", point.stackEnd),
                    width: .ratio(0.68))
                    .foregroundStyle(by: .value("Models", point.seriesName))
                    .accessibilityLabel(Text("\(point.seriesName), \(self.dayText(point.day))"))
                    .accessibilityValue(Text(self.metricText(point.value)))
            }
            if let selectedDay {
                RuleMark(x: .value("Day", selectedDay, unit: .day))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, overflowResolution: .init(
                        x: .fit(to: .chart),
                        y: .fit(to: .chart)))
                    {
                        self.tooltip(selectedDay)
                    }
            }
        }
        .chartXScale(
            domain: self.chartDomain ?? self.fallbackDomain,
            range: .plotDimension(startPadding: 10, endPadding: 30))
        .chartForegroundStyleScale(
            domain: self.presentation.series.map(\.name),
            range: self.presentation.series.indices.map { index in
                self.color(for: index)
            })
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: self.xAxisDates) { value in
                if let date = value.as(Date.self) {
                    AxisValueLabel(anchor: self.xAxisLabelAnchor(for: date)) {
                        Text(self.dayText(date))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(self.metricText(amount))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(height: 220)
        .accessibilityLabel("Models")
        .accessibilityValue(self.chartAccessibilityValue)
        .chartOverlay { proxy in
            GeometryReader { geo in
                MouseLocationReader { location in
                    self.updateSelectedDay(location: location, proxy: proxy, geo: geo)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var ranking: some View {
        self.rankingContent
    }

    private var rankingContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(self.presentation.rows) { row in
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(self.color(for: row))
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    Text(row.source.displayName)
                        .font(.body)
                        .lineLimit(1)
                    Spacer()
                    Text(self.rowDetail(row))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text(self.shareText(row.value))
                        .font(.body.weight(.medium))
                        .monospacedDigit()
                        .frame(width: 58, alignment: .trailing)
                }
            }
        }
    }

    private func rowDetail(_ row: SpendModelsPresentation.Row) -> String {
        guard self.presentation.metric == .tokens else {
            guard let value = row.value else { return "—" }
            let providers = row.source.providerNames.joined(separator: " · ")
            let metric = self.metricText(value)
            return providers.isEmpty ? metric : "\(metric) · \(providers)"
        }
        return spendModelsRowDetailText(row)
    }

    private func shareText(_ value: Double?) -> String {
        guard let value else { return "—" }
        guard let total = self.presentation.metricTotal, total > 0 else { return "—" }
        return UsageFormatter.percentString(value / total * 100)
    }

    private func tooltip(_ day: Date) -> some View {
        let points = self.presentation.points
            .filter { Calendar.current.isDate($0.day, inSameDayAs: day) }
            .sorted { $0.value > $1.value }
        return VStack(alignment: .leading, spacing: 5) {
            Text(self.dayText(day))
                .font(.body.weight(.semibold))
            ForEach(points) { point in
                HStack(spacing: 7) {
                    Circle()
                        .fill(self.color(for: self.seriesIndex(point.seriesID)))
                        .frame(width: 8, height: 8)
                    Text(point.seriesName)
                    Spacer(minLength: 12)
                    Text(self.metricText(point.value))
                        .monospacedDigit()
                }
                .font(.body)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: .black.opacity(0.09), radius: 10, y: 3)
    }

    private var chartAccessibilityValue: String {
        let days = Set(self.presentation.points.map(\.day)).count
        return "\(days) days · \(self.presentation.series.count) models"
    }

    private var fallbackDomain: ClosedRange<Date> {
        let days = self.presentation.points.map(\.day)
        let start = days.min() ?? Date()
        let end = days.max() ?? start
        return start...Calendar.current.date(byAdding: .day, value: 1, to: end)!
    }

    private var xAxisDates: [Date] {
        SpendModelsAxisDates.make(
            selectedDays: self.selectedDays,
            dataDays: self.presentation.points.map(\.day),
            domain: self.chartDomain ?? self.fallbackDomain)
    }

    private func rangeButton(_ days: Int) -> some View {
        Button {
            self.selectedDays = days
            self.selectedDay = nil
        } label: {
            Text(spendModelsDayRangeText(days))
                .font(.body)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    if self.selectedDays == days {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(self.selectedDays == days ? .isSelected : [])
    }

    private func xAxisLabelAnchor(for date: Date) -> UnitPoint {
        if let first = self.xAxisDates.first, Calendar.current.isDate(date, inSameDayAs: first) {
            return .topLeading
        }
        if let last = self.xAxisDates.last, Calendar.current.isDate(date, inSameDayAs: last) {
            return .topTrailing
        }
        return .top
    }

    private func metricText(_ value: Double) -> String {
        UsageFormatter.tokenCountString(Int(value.rounded()))
    }

    private func dayText(_ day: Date) -> String {
        SpendModelsEnglishFormatter.dayText(day)
    }

    private func color(for index: Int) -> Color {
        let accentOpacities = [0.95, 0.76, 0.58, 0.42, 0.30]
        if index < accentOpacities.count {
            return Color.accentColor.opacity(accentOpacities[index])
        }
        let neutralOpacities = [0.30, 0.40, 0.50, 0.60, 0.70]
        return Color(nsColor: .secondaryLabelColor)
            .opacity(neutralOpacities[(index - accentOpacities.count) % neutralOpacities.count])
    }

    private func color(for row: SpendModelsPresentation.Row) -> Color {
        guard let index = self.presentation.series.firstIndex(where: { $0.id == row.id }) else {
            return Color(nsColor: .tertiaryLabelColor).opacity(0.55)
        }
        return self.color(for: index)
    }

    private func seriesIndex(_ id: String) -> Int {
        self.presentation.series.firstIndex(where: { $0.id == id }) ?? 0
    }

    private func updateSelectedDay(location: CGPoint?, proxy: ChartProxy, geo: GeometryProxy) {
        guard let location, let plotAnchor = proxy.plotFrame else {
            self.selectedDay = nil
            return
        }
        let plotFrame = geo[plotAnchor]
        guard plotFrame.contains(location) else {
            self.selectedDay = nil
            return
        }
        let xInPlot = location.x - plotFrame.origin.x
        guard let date: Date = proxy.value(atX: xInPlot) else { return }
        self.selectedDay = Set(self.presentation.points.map(\.day)).min {
            abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date))
        }
    }
}
