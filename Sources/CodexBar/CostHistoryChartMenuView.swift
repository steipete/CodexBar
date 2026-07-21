import Charts
import CodexBarCore
import SwiftUI

@MainActor
struct CostHistoryChartMenuView: View {
    typealias DailyEntry = CostUsageDailyReport.Entry

    enum AxisLabelPlacement: Equatable {
        case hidden
        case centered
        case edges
    }

    /// What the bar chart plots on the Y axis.
    enum ChartMetric: Equatable {
        case cost
        case tokens
    }

    private struct Point: Identifiable {
        let id: String
        let date: Date
        let costUSD: Double?
        let totalTokens: Int?
        let requestCount: Int?
        /// Value used for bar height (cost dollars or token count).
        let chartValue: Double

        init(date: Date, costUSD: Double?, totalTokens: Int?, requestCount: Int?, chartValue: Double) {
            self.date = date
            self.costUSD = costUSD
            self.totalTokens = totalTokens
            self.requestCount = requestCount
            self.chartValue = chartValue
            self.id = "\(Int(date.timeIntervalSince1970))-\(chartValue)"
        }
    }

    private struct DetailRow: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let modeSubtitle: String?
        let accentColor: Color
    }

    private struct DetailContent {
        let primary: String
        let rows: [DetailRow]
    }

    private let provider: UsageProvider
    private let daily: [DailyEntry]
    private let totalCostUSD: Double?
    private let currencyCode: String
    private let historyDays: Int
    private let windowLabel: String?
    private let projects: [CostUsageProjectBreakdown]
    private let sessions: [CostUsageSessionBreakdown]
    private let width: CGFloat
    @State private var selectedDateKey: String?

    init(
        provider: UsageProvider,
        daily: [DailyEntry],
        totalCostUSD: Double?,
        currencyCode: String = "USD",
        historyDays: Int = 30,
        windowLabel: String? = nil,
        projects: [CostUsageProjectBreakdown] = [],
        sessions: [CostUsageSessionBreakdown] = [],
        width: CGFloat)
    {
        self.provider = provider
        self.daily = daily
        self.totalCostUSD = totalCostUSD
        self.currencyCode = currencyCode
        self.historyDays = max(1, min(365, historyDays))
        self.windowLabel = windowLabel
        self.projects = projects
        self.sessions = sessions
        self.width = width
    }

    var body: some View {
        let model = Self.makeModel(provider: self.provider, daily: self.daily)
        let selectedDateKey = self.selectedDateKey ?? Self.defaultSelectedDateKey(model: model)
        VStack(alignment: .leading, spacing: Self.outerSpacing) {
            if model.points.isEmpty {
                Text(L("No cost history data."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L("No cost history data."))
            } else {
                Chart {
                    ForEach(model.points) { point in
                        BarMark(
                            x: .value(L("Day"), point.date, unit: .day),
                            y: .value(model.yAxisTitle, point.chartValue))
                            .foregroundStyle(model.barColor)
                    }
                    if let peak = Self.peakPoint(model: model) {
                        let capStart = max(peak.chartValue - Self.capHeight(maxValue: model.maxChartValue), 0)
                        BarMark(
                            x: .value(L("Day"), peak.date, unit: .day),
                            yStart: .value(L("Cap start"), capStart),
                            yEnd: .value(L("Cap end"), peak.chartValue))
                            .foregroundStyle(Color(nsColor: .systemYellow))
                    }
                }
                .chartYAxis {
                    AxisMarks(
                        position: .leading,
                        values: Self.yAxisTickValues(
                            maxValue: model.maxChartValue,
                            metric: model.chartMetric))
                    { value in
                        AxisGridLine().foregroundStyle(Color.clear)
                        AxisTick().foregroundStyle(Color.clear)
                        AxisValueLabel(centered: false) {
                            if let raw = value.as(Double.self) {
                                Text(Self.yAxisLabelString(
                                    raw,
                                    metric: model.chartMetric,
                                    currencyCode: self.currencyCode))
                                    .font(.caption2)
                                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                                    .padding(.leading, 4)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: model.axisDates) { value in
                        AxisGridLine().foregroundStyle(Color.clear)
                        AxisTick().foregroundStyle(Color.clear)
                        if let date = value.as(Date.self) {
                            AxisValueLabel(anchor: Self.xAxisLabelAnchor(for: date, axisDates: model.axisDates)) {
                                Text(date, format: .dateTime.month(.abbreviated).day())
                                    .font(.caption2)
                                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                            }
                        }
                    }
                }
                .chartLegend(.hidden)
                .frame(height: Self.chartHeight)
                .accessibilityLabel(L("Cost history chart"))
                .accessibilityValue(
                    model.points.isEmpty
                        ? L("No data")
                        : String(format: L("%d days of cost data"), model.points.count))
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

                let detail = self.detailContent(selectedDateKey: selectedDateKey, model: model)
                VStack(alignment: .leading, spacing: Self.detailSpacing) {
                    Text(detail.primary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: Self.detailPrimaryLineHeight, alignment: .leading)
                    if model.detailViewportRowCount > 0 {
                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: Self.detailSpacing) {
                                ForEach(detail.rows) { row in
                                    HStack(alignment: .top, spacing: 8) {
                                        Rectangle()
                                            .fill(row.accentColor)
                                            .frame(
                                                width: 2,
                                                height: Self.accentHeight(
                                                    for: row,
                                                    rowHeight: model.detailRowHeight))
                                            .padding(.top, 1)

                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(row.title)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                                .frame(height: Self.detailTitleLineHeight, alignment: .leading)
                                            if let subtitle = row.subtitle {
                                                Text(subtitle)
                                                    .font(.caption2)
                                                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                                                    .lineLimit(1)
                                                    .truncationMode(.tail)
                                                    .frame(
                                                        height: Self.detailSubtitleLineHeight,
                                                        alignment: .leading)
                                            }
                                            if let modeSubtitle = row.modeSubtitle {
                                                Text(modeSubtitle)
                                                    .font(.caption2)
                                                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                                                    .lineLimit(1)
                                                    .truncationMode(.tail)
                                                    .frame(
                                                        height: Self.detailSubtitleLineHeight,
                                                        alignment: .leading)
                                            }
                                        }
                                    }
                                    .frame(height: model.detailRowHeight, alignment: .leading)
                                }
                            }
                        }
                        .scrollIndicators(
                            Self.detailRowsNeedScrolling(itemCount: detail.rows.count) ? .visible : .hidden)
                        .frame(
                            height: Self.detailRowsViewportHeight(
                                rowCount: model.detailViewportRowCount,
                                rowHeight: model.detailRowHeight),
                            alignment: .topLeading)
                        .id(selectedDateKey)

                        if model.hasDetailOverflow {
                            Text(Self.detailOverflowHint(itemCount: detail.rows.count) ?? " ")
                                .font(.caption2)
                                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                                .frame(height: Self.detailHintHeight, alignment: .leading)
                                .accessibilityHidden(!Self.detailRowsNeedScrolling(itemCount: detail.rows.count))
                        }
                    }
                }
                .frame(
                    height: Self.detailBlockHeight(
                        rowCount: model.detailViewportRowCount,
                        hasOverflow: model.hasDetailOverflow,
                        rowHeight: model.detailRowHeight),
                    alignment: .topLeading)
            }

            VStack(alignment: .leading, spacing: 2) {
                if let total = self.totalCostUSD {
                    Text(String(
                        format: L("Est. total (%@): %@"),
                        self.windowLabel ?? Self.windowLabel(days: self.historyDays),
                        self.costString(total)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(height: Self.detailPrimaryLineHeight, alignment: .leading)
                }
                if let tokenTotal = Self.windowTokenTotal(daily: self.daily), tokenTotal > 0 {
                    Text(String(
                        format: L("Total tokens (%@): %@"),
                        self.windowLabel ?? Self.windowLabel(days: self.historyDays),
                        UsageFormatter.tokenCountString(tokenTotal)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(height: Self.detailPrimaryLineHeight, alignment: .leading)
                }
                if let breakdown = Self.windowTokenBreakdownLine(daily: self.daily) {
                    Text(breakdown)
                        .font(.caption2)
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let disclaimer = Self.estimateDisclaimer(provider: self.provider) {
                    Text(disclaimer)
                        .font(.caption2)
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !self.projects.isEmpty {
                VStack(alignment: .leading, spacing: Self.projectRowSpacing) {
                    Text("Projects")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(height: Self.detailPrimaryLineHeight, alignment: .leading)
                    ForEach(Array(self.projects.prefix(Self.maxVisibleProjectRows)), id: \.projectRowID) { project in
                        let visibleSources = Self.visibleProjectSources(project)
                        VStack(alignment: .leading, spacing: Self.projectSourceSpacing) {
                            self.projectParentRow(project)
                            if !visibleSources.isEmpty {
                                ForEach(
                                    Array(visibleSources.prefix(Self.maxVisibleProjectSourceRows)),
                                    id: \.sourceRowID)
                                { source in
                                    self.projectSourceRow(source)
                                }
                                let hiddenSourceCount = visibleSources.count - Self.maxVisibleProjectSourceRows
                                if hiddenSourceCount > 0 {
                                    Text("+ \(hiddenSourceCount) more")
                                        .font(.caption2)
                                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                                        .lineLimit(1)
                                        .padding(.leading, Self.projectSourceIndent)
                                        .frame(height: Self.projectMoreRowHeight, alignment: .leading)
                                }
                            }
                        }
                        .frame(height: Self.projectEntryHeight(project), alignment: .topLeading)
                    }
                }
                .frame(height: Self.projectBlockHeight(projects: self.projects), alignment: .topLeading)
            }

            if !self.sessions.isEmpty {
                self.sessionsBlock
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, Self.verticalPadding)
        .frame(minWidth: self.width, maxWidth: .infinity, alignment: .top)
    }

    static func estimateDisclaimer(provider: UsageProvider) -> String? {
        switch provider {
        case .codex:
            L("codex_api_estimate_hint")
        case .grok:
            L("Bars show daily tokens. Cost only when Grok reported ticks.")
        default:
            nil
        }
    }

    static func chartMetric(for provider: UsageProvider, daily: [DailyEntry]) -> ChartMetric {
        // Grok subscription paths often omit cost on many days; plot tokens so the chart
        // still reflects activity. Fall back to tokens for any provider when every day lacks cost.
        if provider == .grok { return .tokens }
        let hasAnyCost = daily.contains { ($0.costUSD ?? 0) > 0 }
        return hasAnyCost ? .cost : .tokens
    }

    static func windowTokenTotal(daily: [DailyEntry]) -> Int? {
        let sum = daily.compactMap(\.totalTokens).reduce(0, +)
        return sum > 0 ? sum : nil
    }

    static func windowTokenBreakdownLine(daily: [DailyEntry]) -> String? {
        let input = daily.compactMap(\.inputTokens).reduce(0, +)
        let cache = daily.compactMap(\.cacheReadTokens).reduce(0, +)
        let output = daily.compactMap(\.outputTokens).reduce(0, +)
        guard input + cache + output > 0 else { return nil }
        return String(
            format: L("Uncached %@ · Cache %@ · Output %@"),
            UsageFormatter.tokenCountString(input),
            UsageFormatter.tokenCountString(cache),
            UsageFormatter.tokenCountString(output))
    }

    private struct Model {
        let points: [Point]
        let pointsByDateKey: [String: Point]
        let entriesByDateKey: [String: DailyEntry]
        let dateKeys: [(key: String, date: Date)]
        let axisDates: [Date]
        let barColor: Color
        let peakKey: String?
        let maxChartValue: Double
        let chartMetric: ChartMetric
        let yAxisTitle: String
        let detailViewportRowCount: Int
        let hasDetailOverflow: Bool
        let detailRowHeight: CGFloat
    }

    private static let selectionBandColor = Color(nsColor: .labelColor).opacity(0.1)
    static let maxVisibleDetailLines = 4
    private static let detailPrimaryLineHeight: CGFloat = 16
    private static let detailTitleLineHeight: CGFloat = 16
    private static let detailSubtitleLineHeight: CGFloat = 13
    private static let compactDetailRowHeight: CGFloat = 36
    private static let expandedDetailRowHeight: CGFloat = 44
    private static let detailSpacing: CGFloat = 6
    private static let detailHintHeight: CGFloat = 13
    private static let chartHeight: CGFloat = 130
    private static let outerSpacing: CGFloat = 10
    private static let projectRowHeight: CGFloat = 31
    private static let projectRowSpacing: CGFloat = 5
    private static let maxVisibleProjectRows = 10
    private static let projectSourceRowHeight: CGFloat = 29
    private static let projectSourceSpacing: CGFloat = 3
    private static let projectSourceIndent: CGFloat = 10
    private static let projectMoreRowHeight: CGFloat = 16
    private static let maxVisibleProjectSourceRows = 2
    private static let sessionRowHeight: CGFloat = 44
    private static let sessionRowSpacing: CGFloat = 5
    private static let maxVisibleSessionRows = 5
    static let verticalPadding: CGFloat = 10

    private var sessionsBlock: some View {
        let visibleCount = min(self.sessions.count, Self.maxVisibleSessionRows)
        return VStack(alignment: .leading, spacing: Self.sessionRowSpacing) {
            HStack {
                Text("Conversations (\(self.windowLabel ?? Self.windowLabel(days: self.historyDays)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(self.sessions.count)")
                    .font(.caption2)
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            }
            .frame(height: Self.detailPrimaryLineHeight, alignment: .leading)

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: Self.sessionRowSpacing) {
                    ForEach(self.sessions) { session in
                        self.sessionRow(session)
                    }
                }
            }
            .scrollIndicators(self.sessions.count > visibleCount ? .visible : .hidden)
            .frame(
                height: CGFloat(visibleCount) * Self.sessionRowHeight
                    + CGFloat(max(visibleCount - 1, 0)) * Self.sessionRowSpacing,
                alignment: .topLeading)
        }
        .frame(
            height: Self.detailPrimaryLineHeight + Self.sessionRowSpacing
                + CGFloat(visibleCount) * Self.sessionRowHeight
                + CGFloat(max(visibleCount - 1, 0)) * Self.sessionRowSpacing,
            alignment: .topLeading)
    }

    private func sessionRow(_ session: CostUsageSessionBreakdown) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Session \(Self.shortSessionID(session.sessionID))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(Self.sessionUsageLine(session))
                    .font(.caption2)
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(session.lastActivity, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(session.costUSD.map(self.costString) ?? "—")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(height: Self.sessionRowHeight, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    static func shortSessionID(_ sessionID: String) -> String {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 12 else { return trimmed }
        return "\(trimmed.prefix(4))...\(trimmed.suffix(8))"
    }

    private static func sessionUsageLine(_ session: CostUsageSessionBreakdown) -> String {
        let models = session.modelBreakdowns.map(\.modelName)
        let modelLabel = if models.isEmpty {
            "Unknown model"
        } else if models.count == 1 {
            models[0]
        } else {
            "\(models[0]) +\(models.count - 1)"
        }
        let input = session.inputTokens.map(UsageFormatter.tokenCountString) ?? "—"
        let cached = session.cachedInputTokens.map(UsageFormatter.tokenCountString) ?? "—"
        let output = session.outputTokens.map(UsageFormatter.tokenCountString) ?? "—"
        return "\(modelLabel) · \(input) input · \(cached) cached · \(output) output"
    }

    static func windowLabel(days: Int) -> String {
        if days == 1 {
            return L("Today")
        }
        return String(format: L("Last %d days"), days)
    }

    private static func accentHeight(for row: DetailRow, rowHeight: CGFloat) -> CGFloat {
        row.subtitle == nil && row.modeSubtitle == nil ? 14 : rowHeight
    }

    private static func capHeight(maxValue: Double) -> Double {
        maxValue * 0.05
    }

    /// Y-axis tick values: 0, mid, max for large ranges; 0 and max for small; empty for flat data.
    private static func yAxisTickValues(maxValue: Double, metric: ChartMetric) -> [Double] {
        guard maxValue > 0 else { return [] }
        let smallThreshold: Double = metric == .cost ? 1.0 : 1000
        if maxValue < smallThreshold {
            return [0, maxValue]
        }
        return [0, maxValue / 2, maxValue]
    }

    private static func makeModel(provider: UsageProvider, daily: [DailyEntry]) -> Model {
        let metric = self.chartMetric(for: provider, daily: daily)
        let sorted = daily.sorted { lhs, rhs in lhs.date < rhs.date }
        var points: [Point] = []
        points.reserveCapacity(sorted.count)

        var pointsByKey: [String: Point] = [:]
        pointsByKey.reserveCapacity(sorted.count)

        var entriesByKey: [String: DailyEntry] = [:]
        entriesByKey.reserveCapacity(sorted.count)

        var dateKeys: [(key: String, date: Date)] = []
        dateKeys.reserveCapacity(sorted.count)

        var peak: (key: String, value: Double)?
        var maxChartValue: Double = 0
        var maxDetailRows = 0
        var hasModeDetails = false
        for entry in sorted {
            guard let (date, chartValue, costUSD) = self.chartPointInput(for: entry, metric: metric)
            else { continue }
            let point = Point(
                date: date,
                costUSD: costUSD,
                totalTokens: entry.totalTokens,
                requestCount: entry.requestCount,
                chartValue: chartValue)
            points.append(point)
            pointsByKey[entry.date] = point
            entriesByKey[entry.date] = entry
            dateKeys.append((entry.date, date))
            // Detail rows: models + optional token breakdown rows for Grok-style entries.
            let modelBreakdowns = entry.modelBreakdowns ?? []
            var detailRowCount = modelBreakdowns.count
            if entry.inputTokens != nil || entry.cacheReadTokens != nil || entry.outputTokens != nil {
                detailRowCount += 1
            }
            maxDetailRows = max(maxDetailRows, detailRowCount)
            hasModeDetails = hasModeDetails || modelBreakdowns.contains { Self.hasModeSubtitle($0) }
            if let cur = peak {
                if chartValue > cur.value {
                    peak = (entry.date, chartValue)
                }
            } else {
                peak = (entry.date, chartValue)
            }
            maxChartValue = max(maxChartValue, chartValue)
        }

        let axisDates: [Date] = {
            guard let first = dateKeys.first?.date, let last = dateKeys.last?.date else { return [] }
            if Calendar.current.isDate(first, inSameDayAs: last) {
                return [first]
            }
            return [first, last]
        }()

        let barColor = Self.barColor(for: provider)
        let yAxisTitle = metric == .tokens ? L("Tokens") : L("Cost")
        return Model(
            points: points,
            pointsByDateKey: pointsByKey,
            entriesByDateKey: entriesByKey,
            dateKeys: dateKeys,
            axisDates: axisDates,
            barColor: barColor,
            peakKey: maxChartValue > 0 ? peak?.key : nil,
            maxChartValue: maxChartValue,
            chartMetric: metric,
            yAxisTitle: yAxisTitle,
            detailViewportRowCount: min(maxDetailRows, self.maxVisibleDetailLines),
            hasDetailOverflow: maxDetailRows > self.maxVisibleDetailLines,
            detailRowHeight: hasModeDetails ? self.expandedDetailRowHeight : self.compactDetailRowHeight)
    }

    private static func axisLabelPlacement(for dates: [Date]) -> AxisLabelPlacement {
        switch dates.count {
        case 0: .hidden
        case 1: .centered
        default: .edges
        }
    }

    private static func xAxisLabelAnchor(for date: Date, axisDates: [Date]) -> UnitPoint {
        switch self.axisLabelPlacement(for: axisDates) {
        case .hidden, .centered:
            .top
        case .edges:
            if let first = axisDates.first, Calendar.current.isDate(date, inSameDayAs: first) {
                .topLeading
            } else if let last = axisDates.last, Calendar.current.isDate(date, inSameDayAs: last) {
                .topTrailing
            } else {
                .top
            }
        }
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

    /// Builds a chart point for a daily entry.
    /// - Cost metric: requires a non-nil cost (legacy Codex behavior).
    /// - Tokens metric: includes any day with token activity, even when cost is missing.
    private static func chartPointInput(
        for entry: DailyEntry,
        metric: ChartMetric) -> (date: Date, chartValue: Double, costUSD: Double?)?
    {
        guard let date = self.dateFromDayKey(entry.date) else { return nil }
        switch metric {
        case .cost:
            guard let costUSD = entry.costUSD, costUSD >= 0 else { return nil }
            return (date, costUSD, costUSD)
        case .tokens:
            let tokens = entry.totalTokens ?? 0
            guard tokens > 0 || (entry.costUSD ?? 0) > 0 else { return nil }
            return (date, Double(tokens), entry.costUSD)
        }
    }

    private static func peakPoint(model: Model) -> Point? {
        guard let key = model.peakKey else { return nil }
        return model.pointsByDateKey[key]
    }

    private static func hasModeSubtitle(_ item: CostUsageDailyReport.ModelBreakdown) -> Bool {
        item.standardCostUSD != nil || item.priorityCostUSD != nil
    }

    private static func detailRowsViewportHeight(rowCount: Int, rowHeight: CGFloat) -> CGFloat {
        guard rowCount > 0 else { return 0 }
        return CGFloat(rowCount) * rowHeight + CGFloat(rowCount - 1) * self.detailSpacing
    }

    private static func detailBlockHeight(rowCount: Int, hasOverflow: Bool, rowHeight: CGFloat) -> CGFloat {
        guard rowCount > 0 else { return self.detailPrimaryLineHeight }
        var height = self.detailPrimaryLineHeight + self.detailSpacing
        height += self.detailRowsViewportHeight(rowCount: rowCount, rowHeight: rowHeight)
        if hasOverflow {
            height += self.detailSpacing + self.detailHintHeight
        }
        return height
    }

    private static func projectBlockHeight(projects: [CostUsageProjectBreakdown]) -> CGFloat {
        let visibleProjects = Array(projects.prefix(self.maxVisibleProjectRows))
        guard !visibleProjects.isEmpty else { return 0 }
        return self.detailPrimaryLineHeight
            + self.projectRowSpacing
            + visibleProjects.reduce(CGFloat(0)) { $0 + self.projectEntryHeight($1) }
            + CGFloat(max(visibleProjects.count - 1, 0)) * self.projectRowSpacing
    }

    private static func projectEntryHeight(_ project: CostUsageProjectBreakdown) -> CGFloat {
        let sources = self.visibleProjectSources(project)
        guard !sources.isEmpty else { return self.projectRowHeight }
        let visibleSources = min(sources.count, self.maxVisibleProjectSourceRows)
        let moreRows = sources.count > self.maxVisibleProjectSourceRows ? 1 : 0
        return self.projectRowHeight
            + CGFloat(visibleSources) * (self.projectSourceRowHeight + self.projectSourceSpacing)
            + CGFloat(moreRows) * (self.projectMoreRowHeight + self.projectSourceSpacing)
    }

    static func visibleProjectSources(
        _ project: CostUsageProjectBreakdown) -> [CostUsageProjectSourceBreakdown]
    {
        guard project.sources.count == 1 else { return project.sources }
        guard let source = project.sources.first, source.path != project.path else { return [] }
        return [source]
    }

    private static func defaultSelectedDateKey(model: Model) -> String? {
        model.dateKeys.last?.key
    }

    private func selectionBandRect(model: Model, proxy: ChartProxy, geo: GeometryProxy) -> CGRect? {
        guard let key = self.selectedDateKey else { return nil }
        guard let plotAnchor = proxy.plotFrame else { return nil }
        let plotFrame = geo[plotAnchor]
        guard let index = model.dateKeys.firstIndex(where: { $0.key == key }) else { return nil }
        let date = model.dateKeys[index].date
        guard let x = proxy.position(forX: date) else { return nil }

        // Use the calendar day slot width so the band stays the same size regardless of data gaps.
        let nextDayX = proxy.position(forX: ChartBarHoverSelection.nextCalendarDay(after: date)) ?? (x + 20)
        let slotWidth = abs(nextDayX - x)
        let barHalfWidth = slotWidth * 0.25 + 2

        let left = plotFrame.origin.x + x - barHalfWidth
        let right = plotFrame.origin.x + x + barHalfWidth
        return CGRect(x: left, y: plotFrame.origin.y, width: right - left, height: plotFrame.height)
    }

    private func updateSelection(
        location: CGPoint?,
        model: Model,
        proxy: ChartProxy,
        geo: GeometryProxy)
    {
        // Keep the last hovered day selected when the pointer leaves the chart so the adjacent
        // model-breakdown scroller remains interactive. The selection resets with the menu view.
        guard let location else { return }

        guard let plotAnchor = proxy.plotFrame else { return }
        let plotFrame = geo[plotAnchor]
        guard plotFrame.contains(location) else { return }

        let xInPlot = location.x - plotFrame.origin.x
        guard let date: Date = proxy.value(atX: xInPlot) else { return }
        guard let nearest = self.nearestDateKey(to: date, model: model) else { return }

        // Stay on the last selected bar when cursor is in the gap between bars.
        if let nearestEntry = model.dateKeys.first(where: { $0.key == nearest }),
           let barX = proxy.position(forX: nearestEntry.date)
        {
            let nextDayX = proxy.position(forX: ChartBarHoverSelection.nextCalendarDay(after: nearestEntry.date)) ??
                (barX + 20)
            let slotWidth = abs(nextDayX - barX)
            guard ChartBarHoverSelection.accepts(
                distanceFromBarCenter: abs(location.x - (plotFrame.origin.x + barX)),
                barHalfWidth: slotWidth * 0.25 + 2,
                selectableCount: model.dateKeys.count)
            else { return }
        }

        if self.selectedDateKey != nearest {
            self.selectedDateKey = nearest
        }
    }

    private func projectSummary(_ project: CostUsageProjectBreakdown) -> String {
        let cost = project.totalCostUSD
            .map { self.costString($0) } ?? "—"
        guard let totalTokens = project.totalTokens else { return cost }
        return "\(cost) · \(L("%@ tokens", UsageFormatter.tokenCountString(totalTokens)))"
    }

    private func projectParentRow(_ project: CostUsageProjectBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Text(project.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(self.projectSummary(project))
                    .font(.caption2)
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if let path = project.path {
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(height: Self.projectRowHeight, alignment: .leading)
    }

    private func projectSourceRow(_ source: CostUsageProjectSourceBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(source.name)
                    .font(.caption2)
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(self.projectSourceSummary(source))
                    .font(.caption2)
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if let path = source.path {
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(Color(nsColor: .quaternaryLabelColor))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.leading, Self.projectSourceIndent)
        .frame(height: Self.projectSourceRowHeight, alignment: .leading)
    }

    private func projectSourceSummary(_ source: CostUsageProjectSourceBreakdown) -> String {
        let cost = source.totalCostUSD
            .map { self.costString($0) } ?? "—"
        guard let totalTokens = source.totalTokens else { return cost }
        return "\(cost) · \(L("%@ tokens", UsageFormatter.tokenCountString(totalTokens)))"
    }

    private func nearestDateKey(to date: Date, model: Model) -> String? {
        guard !model.dateKeys.isEmpty else { return nil }
        var best: (key: String, distance: TimeInterval)?
        for entry in model.dateKeys {
            let dist = abs(entry.date.timeIntervalSince(date))
            if let cur = best {
                if dist < cur.distance {
                    best = (entry.key, dist)
                }
            } else {
                best = (entry.key, dist)
            }
        }
        return best?.key
    }

    private func detailContent(selectedDateKey: String?, model: Model) -> DetailContent {
        guard let key = selectedDateKey,
              let point = model.pointsByDateKey[key],
              let date = Self.dateFromDayKey(key)
        else {
            return DetailContent(primary: L("Hover a bar for details"), rows: [])
        }

        let dayLabel = date.formatted(.dateTime.month(.abbreviated).day())
        var parts: [String] = []
        if let cost = point.costUSD {
            parts.append(self.costString(cost))
        } else {
            parts.append("—")
        }
        if let tokens = point.totalTokens {
            parts.append("\(UsageFormatter.tokenCountString(tokens)) tokens")
        }
        if let requests = point.requestCount {
            parts.append("\(UsageFormatter.tokenCountString(requests)) calls")
        }
        let primary = "\(dayLabel): \(parts.joined(separator: " · "))"
        return DetailContent(primary: primary, rows: self.breakdownRows(key: key, model: model))
    }

    private func breakdownRows(key: String, model: Model) -> [DetailRow] {
        guard let entry = model.entriesByDateKey[key] else { return [] }
        var rows: [DetailRow] = []

        // Token composition row (uncached / cache / output) when available.
        if entry.inputTokens != nil || entry.cacheReadTokens != nil || entry.outputTokens != nil {
            let uncached = entry.inputTokens.map(UsageFormatter.tokenCountString) ?? "—"
            let cache = entry.cacheReadTokens.map(UsageFormatter.tokenCountString) ?? "—"
            let output = entry.outputTokens.map(UsageFormatter.tokenCountString) ?? "—"
            rows.append(DetailRow(
                id: "token-breakdown-\(key)",
                title: L("Token breakdown"),
                subtitle: String(format: L("Uncached %@ · Cache %@ · Output %@"), uncached, cache, output),
                modeSubtitle: nil,
                accentColor: model.barColor.opacity(0.9)))
        }

        guard let breakdown = entry.modelBreakdowns, !breakdown.isEmpty else { return rows }

        rows.append(contentsOf: Self.orderedBreakdownItems(breakdown)
            .enumerated()
            .map { index, item in
                DetailRow(
                    id: "\(item.modelName)-\(index)",
                    title: UsageFormatter.modelDisplayName(item.modelName),
                    subtitle: self.modelBreakdownTotalSubtitle(item),
                    modeSubtitle: self.modelBreakdownModeSubtitle(item),
                    accentColor: model.barColor.opacity(Self.breakdownAccentOpacity(for: index)))
            })
        return rows
    }

    static func orderedBreakdownItems(
        _ breakdown: [CostUsageDailyReport.ModelBreakdown]) -> [CostUsageDailyReport.ModelBreakdown]
    {
        breakdown.sorted { lhs, rhs in
            let lCost = lhs.costUSD ?? -1
            let rCost = rhs.costUSD ?? -1
            if lCost != rCost {
                return lCost > rCost
            }

            let lTokens = lhs.totalTokens ?? -1
            let rTokens = rhs.totalTokens ?? -1
            if lTokens != rTokens {
                return lTokens > rTokens
            }

            return lhs.modelName > rhs.modelName
        }
    }

    static func detailViewportRowCount(itemCount: Int) -> Int {
        min(max(itemCount, 0), self.maxVisibleDetailLines)
    }

    static func detailRowsNeedScrolling(itemCount: Int) -> Bool {
        itemCount > self.maxVisibleDetailLines
    }

    static func detailOverflowHint(itemCount: Int) -> String? {
        self.detailRowsNeedScrolling(itemCount: itemCount) ? L("Scroll to see more models") : nil
    }

    private func modelBreakdownTotalSubtitle(_ item: CostUsageDailyReport.ModelBreakdown) -> String? {
        UsageFormatter.modelCostDetail(
            item.modelName,
            costUSD: item.costUSD,
            totalTokens: item.totalTokens,
            currencyCode: self.currencyCode)
    }

    private func modelBreakdownModeSubtitle(_ item: CostUsageDailyReport.ModelBreakdown) -> String? {
        var parts: [String] = []
        if let standardCost = item.standardCostUSD {
            var standardPart = "Std \(self.costString(standardCost))"
            if let standardTokens = item.standardTokens {
                standardPart += " · \(UsageFormatter.tokenCountString(standardTokens))"
            }
            parts.append(standardPart)
        }
        if let priorityCost = item.priorityCostUSD {
            var priorityPart = "Fast \(self.costString(priorityCost))"
            if let priorityTokens = item.priorityTokens {
                priorityPart += " · \(UsageFormatter.tokenCountString(priorityTokens))"
            }
            parts.append(priorityPart)
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " / ")
    }

    private func costString(_ value: Double) -> String {
        Self.costString(value, currencyCode: self.currencyCode)
    }

    private static func costString(_ value: Double, currencyCode: String) -> String {
        UsageFormatter.currencyString(value, currencyCode: currencyCode)
    }

    private static func yAxisLabelString(
        _ value: Double,
        metric: ChartMetric,
        currencyCode: String) -> String
    {
        switch metric {
        case .cost:
            return self.yAxisCostString(value, currencyCode: currencyCode)
        case .tokens:
            if value >= 1_000_000 {
                return String(format: "%.1fM", value / 1_000_000)
            }
            if value >= 1_000 {
                return String(format: "%.0fK", value / 1_000)
            }
            return String(format: "%.0f", value)
        }
    }

    private static func yAxisCostString(_ value: Double, currencyCode: String) -> String {
        UsageFormatter.compactCurrencyString(value, currencyCode: currencyCode)
    }

    private static func breakdownAccentOpacity(for index: Int) -> Double {
        let opacity = 0.75 - (Double(index) * 0.12)
        return max(0.3, opacity)
    }
}

extension CostHistoryChartMenuView {
    struct RenderFingerprint: Equatable {
        let currencyCode: String
        let historyDays: Int
        let windowLabel: String?
        let totalCostBitPattern: UInt64?
        let hasDailyEntries: Bool
        let daily: [VisibleDailyFingerprint]
        let projects: [VisibleProjectFingerprint]
        let sessions: [VisibleSessionFingerprint]
    }

    struct VisibleDailyFingerprint: Equatable {
        let date: String
        let totalTokens: Int?
        let requestCount: Int?
        let costBitPattern: UInt64?
        let modelBreakdowns: [VisibleModelBreakdownFingerprint]
    }

    struct VisibleModelBreakdownFingerprint: Equatable {
        let modelName: String
        let costBitPattern: UInt64?
        let totalTokens: Int?
        let standardCostBitPattern: UInt64?
        let priorityCostBitPattern: UInt64?
        let standardTokens: Int?
        let priorityTokens: Int?
    }

    struct VisibleProjectFingerprint: Equatable {
        let name: String
        let path: String?
        let totalTokens: Int?
        let totalCostBitPattern: UInt64?
        let visibleSourceCount: Int
        let sources: [VisibleSourceFingerprint]
    }

    struct VisibleSourceFingerprint: Equatable {
        let name: String
        let path: String?
        let totalTokens: Int?
        let totalCostBitPattern: UInt64?
    }

    struct VisibleSessionFingerprint: Equatable {
        let sessionID: String
        let lastActivityBitPattern: UInt64
        let inputTokens: Int?
        let cachedInputTokens: Int?
        let outputTokens: Int?
        let totalTokens: Int?
        let costBitPattern: UInt64?
        let models: [VisibleModelBreakdownFingerprint]
    }

    static func renderFingerprint(
        from snapshot: CostUsageTokenSnapshot,
        provider: UsageProvider) -> RenderFingerprint
    {
        let projects = (provider == .codex || provider == .grok) ? snapshot.projects : []
        let sessions = (provider == .codex || provider == .grok) ? snapshot.sessions : []
        let metric = self.chartMetric(for: provider, daily: snapshot.daily)
        return RenderFingerprint(
            currencyCode: snapshot.currencyCode,
            historyDays: snapshot.historyDays,
            windowLabel: snapshot.historyLabel,
            totalCostBitPattern: snapshot.last30DaysCostUSD.map(\.bitPattern),
            hasDailyEntries: !snapshot.daily.isEmpty,
            daily: snapshot.daily
                .filter { self.chartPointInput(for: $0, metric: metric) != nil }
                .sorted { $0.date < $1.date }
                .map(self.visibleDailyFingerprint),
            projects: Array(projects.prefix(self.maxVisibleProjectRows)).map { project in
                let visibleSources = self.visibleProjectSources(project)
                return VisibleProjectFingerprint(
                    name: project.name,
                    path: project.path,
                    totalTokens: project.totalTokens,
                    totalCostBitPattern: project.totalCostUSD.map(\.bitPattern),
                    visibleSourceCount: visibleSources.count,
                    sources: Array(visibleSources.prefix(self.maxVisibleProjectSourceRows)).map { source in
                        VisibleSourceFingerprint(
                            name: source.name,
                            path: source.path,
                            totalTokens: source.totalTokens,
                            totalCostBitPattern: source.totalCostUSD.map(\.bitPattern))
                    })
            },
            sessions: sessions.map { session in
                VisibleSessionFingerprint(
                    sessionID: session.sessionID,
                    lastActivityBitPattern: session.lastActivity.timeIntervalSince1970.bitPattern,
                    inputTokens: session.inputTokens,
                    cachedInputTokens: session.cachedInputTokens,
                    outputTokens: session.outputTokens,
                    totalTokens: session.totalTokens,
                    costBitPattern: session.costUSD.map(\.bitPattern),
                    models: session.modelBreakdowns.map { item in
                        VisibleModelBreakdownFingerprint(
                            modelName: item.modelName,
                            costBitPattern: item.costUSD.map(\.bitPattern),
                            totalTokens: item.totalTokens,
                            standardCostBitPattern: item.standardCostUSD.map(\.bitPattern),
                            priorityCostBitPattern: item.priorityCostUSD.map(\.bitPattern),
                            standardTokens: item.standardCostUSD == nil ? nil : item.standardTokens,
                            priorityTokens: item.priorityCostUSD == nil ? nil : item.priorityTokens)
                    })
            })
    }

    private static func visibleDailyFingerprint(_ entry: DailyEntry) -> VisibleDailyFingerprint {
        VisibleDailyFingerprint(
            date: entry.date,
            totalTokens: entry.totalTokens,
            requestCount: entry.requestCount,
            costBitPattern: entry.costUSD.map(\.bitPattern),
            modelBreakdowns: self.orderedBreakdownItems(entry.modelBreakdowns ?? []).map { item in
                VisibleModelBreakdownFingerprint(
                    modelName: item.modelName,
                    costBitPattern: item.costUSD.map(\.bitPattern),
                    totalTokens: item.totalTokens,
                    standardCostBitPattern: item.standardCostUSD.map(\.bitPattern),
                    priorityCostBitPattern: item.priorityCostUSD.map(\.bitPattern),
                    standardTokens: item.standardCostUSD == nil ? nil : item.standardTokens,
                    priorityTokens: item.priorityCostUSD == nil ? nil : item.priorityTokens)
            })
    }

    static func _defaultSelectedDateKeyForTesting(provider: UsageProvider, daily: [DailyEntry]) -> String? {
        self.defaultSelectedDateKey(model: self.makeModel(provider: provider, daily: daily))
    }

    static func _axisDatesForTesting(provider: UsageProvider, daily: [DailyEntry]) -> [Date] {
        self.makeModel(provider: provider, daily: daily).axisDates
    }

    static func _axisLabelPlacementForTesting(
        provider: UsageProvider,
        daily: [DailyEntry]) -> AxisLabelPlacement
    {
        self.axisLabelPlacement(for: self.makeModel(provider: provider, daily: daily).axisDates)
    }

    static func _yAxisTickValuesForTesting(maxCostUSD: Double) -> [Double] {
        self.yAxisTickValues(maxValue: maxCostUSD, metric: .cost)
    }

    static func _yAxisCostStringForTesting(_ value: Double, currencyCode: String = "USD") -> String {
        self.yAxisCostString(value, currencyCode: currencyCode)
    }

    static func _detailViewportConfigurationForTesting(
        provider: UsageProvider,
        daily: [DailyEntry]) -> (rowCount: Int, hasOverflow: Bool, rowHeight: CGFloat)
    {
        let model = self.makeModel(provider: provider, daily: daily)
        return (model.detailViewportRowCount, model.hasDetailOverflow, model.detailRowHeight)
    }
}

extension CostUsageProjectBreakdown {
    fileprivate var projectRowID: String {
        self.path ?? "unknown:\(self.name)"
    }
}

extension CostUsageProjectSourceBreakdown {
    fileprivate var sourceRowID: String {
        self.path ?? "unknown:\(self.name)"
    }
}
