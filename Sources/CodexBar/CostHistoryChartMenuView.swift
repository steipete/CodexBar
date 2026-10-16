import AppKit
import Charts
import CodexBarCore
import SwiftUI

@MainActor
// swiftlint:disable:next type_body_length
struct CostHistoryChartMenuView: View {
    typealias DailyEntry = CostUsageDailyReport.Entry

    enum ChartMetric: CaseIterable, Hashable {
        case tokens
        case cost

        var title: String {
            switch self {
            case .tokens: L("Token")
            case .cost: L("Cost")
            }
        }
    }

    private struct Point: Identifiable {
        let id: String
        let date: Date
        let value: Double
        let costUSD: Double?
        let totalTokens: Int?
        let requestCount: Int?
        let incompleteRequestCount: Int

        init(
            date: Date,
            value: Double,
            costUSD: Double?,
            totalTokens: Int?,
            requestCount: Int?,
            incompleteRequestCount: Int)
        {
            self.date = date
            self.value = value
            self.costUSD = costUSD
            self.totalTokens = totalTokens
            self.requestCount = requestCount
            self.incompleteRequestCount = incompleteRequestCount
            self.id = "\(Int(date.timeIntervalSince1970))"
        }
    }

    struct DetailRow: Identifiable {
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

    private struct DetailLayout {
        let viewportRowCount: Int
        let hasOverflow: Bool
        let rowHeight: CGFloat
    }

    private let provider: UsageProvider
    private let daily: [DailyEntry]
    private let totalCostUSD: Double?
    private let currencyCode: String
    /// Multiplier applied to source-currency amounts at display time so labels can render
    /// in the user's preferred currency while chart geometry stays in source values.
    private let costMultiplier: Double
    private let historyCoverageIsEstablished: Bool
    private let windowLabel: String
    private let projects: [CostUsageProjectBreakdown]
    private let sessions: [CostUsageSessionBreakdown]
    private let hidePersonalInfo: Bool
    private let width: CGFloat
    private let onDetailHeightChanged: (@MainActor (CGFloat, @MainActor () -> Void) -> Void)?
    private let onMetricChanged: (@MainActor (ChartMetric) -> Void)?
    @State private var metric: ChartMetric
    @State private var selectedDateKey: String?

    init(
        provider: UsageProvider,
        daily: [DailyEntry],
        totalCostUSD: Double?,
        currencyCode: String = "USD",
        costMultiplier: Double = 1,
        historyDays: Int = 30,
        historyCoverageIsEstablished: Bool = true,
        windowLabel: String? = nil,
        projects: [CostUsageProjectBreakdown] = [],
        sessions: [CostUsageSessionBreakdown] = [],
        hidePersonalInfo: Bool,
        width: CGFloat,
        onMetricChanged: (@MainActor (ChartMetric) -> Void)? = nil,
        onDetailHeightChanged: (@MainActor (CGFloat, @MainActor () -> Void) -> Void)? = nil)
    {
        self.provider = provider
        self.daily = daily
        self.totalCostUSD = totalCostUSD
        self.currencyCode = currencyCode
        self.costMultiplier = costMultiplier
        self.historyCoverageIsEstablished = historyCoverageIsEstablished
        self.windowLabel = windowLabel.map { L($0) } ?? Self.windowLabel(days: max(1, historyDays))
        self.projects = projects
        self.sessions = sessions
        self.hidePersonalInfo = hidePersonalInfo
        self.width = width
        self.onDetailHeightChanged = onDetailHeightChanged
        self.onMetricChanged = onMetricChanged
        self._metric = State(initialValue: Self.defaultMetric(provider: provider, daily: daily))
    }

    var body: some View {
        let availableMetrics = Self.availableMetrics(provider: self.provider, daily: self.daily)
        let activeMetric = availableMetrics.contains(self.metric)
            ? self.metric
            : Self.defaultMetric(provider: self.provider, daily: self.daily)
        let model = Self.makeModel(provider: self.provider, daily: self.daily, metric: activeMetric)
        let showsHistoryRefreshing = Self.showsHistoryRefreshing(
            provider: self.provider,
            metric: activeMetric,
            historyCoverageIsEstablished: self.historyCoverageIsEstablished)
        let selectedDateKey = self.selectedDateKey.flatMap { model.pointsByDateKey[$0] == nil ? nil : $0 }
            ?? Self.defaultSelectedDateKey(model: model)
        let detailLayout = Self.detailLayout(entry: selectedDateKey.flatMap { model.entriesByDateKey[$0] })
        let detailHeight = Self.detailBlockHeight(
            rowCount: detailLayout.viewportRowCount,
            hasOverflow: detailLayout.hasOverflow,
            rowHeight: detailLayout.rowHeight)
        let incompleteCount = CostUsageIncompleteRequests.sum(self.daily.map(\.incompleteRequestCount))
        let tokenValues = model.points.compactMap(\.totalTokens)
        let accessibilityTokens = tokenValues.isEmpty ? nil : CheckedSum.integers(tokenValues)
        VStack(alignment: .leading, spacing: Self.outerSpacing) {
            if model.points.isEmpty {
                Text(L("No data available"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L("No data available"))
            } else {
                Chart {
                    ForEach(model.points) { point in
                        let hasValue = activeMetric == .cost ? point.costUSD != nil : point.totalTokens != nil
                        if hasValue {
                            BarMark(
                                x: .value(L("Day"), point.date, unit: .day),
                                y: .value(activeMetric.title, point.value),
                                width: .ratio(ChartBarHoverSelection.barWidthRatio))
                                .foregroundStyle(model.barColor)
                        }
                        if point.incompleteRequestCount > 0 {
                            PointMark(
                                x: .value(L("Day"), point.date, unit: .day),
                                y: .value(activeMetric.title, point.value))
                                .symbol(.diamond)
                                .symbolSize(20)
                                .foregroundStyle(Color.secondary)
                                .accessibilityLabel(L("Incomplete"))
                                .accessibilityValue(hasValue ? self
                                    .yAxisString(point.value, metric: activeMetric) : "—")
                        }
                    }
                    if let peak = Self.peakPoint(model: model) {
                        let capStart = max(peak.value - Self.capHeight(maxValue: model.maxValue), 0)
                        BarMark(
                            x: .value(L("Day"), peak.date, unit: .day),
                            yStart: .value(L("Cap start"), capStart),
                            yEnd: .value(L("Cap end"), peak.value),
                            width: .ratio(ChartBarHoverSelection.barWidthRatio))
                            .foregroundStyle(Color(nsColor: .systemYellow))
                    }
                }
                .chartYAxis {
                    AxisMarks(
                        position: .leading,
                        values: Self.yAxisTickValues(maxValue: model.maxValue, metric: activeMetric))
                    { value in
                        AxisGridLine().foregroundStyle(Color.clear)
                        AxisTick().foregroundStyle(Color.clear)
                        AxisValueLabel(centered: false) {
                            if let raw = value.as(Double.self) {
                                Text(self.yAxisString(raw, metric: activeMetric))
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
                            AxisValueLabel(anchor: ChartAxisLabelLayout.barCenteredAnchor) {
                                ChartAxisLabelLayout.dateLabel(
                                    Text(date, format: .dateTime.month(.abbreviated).day()))
                            }
                        }
                    }
                }
                .chartLegend(.hidden)
                .frame(height: Self.chartHeight)
                .accessibilityLabel(activeMetric == .tokens ? L("Token activity") : L("Cost history chart"))
                .accessibilityValue(
                    (activeMetric == .tokens
                        ? accessibilityTokens.map { L("%@ tokens", UsageFormatter.tokenCountString($0)) } ?? "—"
                        : String(format: L("%d days of cost data"), model.points.count))
                        + UsageFormatter.incompleteUsageSuffix(incompleteCount))
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

                if availableMetrics.count > 1 || showsHistoryRefreshing {
                    HStack {
                        if showsHistoryRefreshing {
                            Text(L("Refreshing"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(L("Refreshing"))
                        }
                        Spacer(minLength: 0)
                        if availableMetrics.count > 1 {
                            Picker(L("Display mode"), selection: Binding(
                                get: { self.metric },
                                set: { self.updateMetric($0) }))
                            {
                                ForEach(availableMetrics, id: \.self) { metric in
                                    Text(metric.title).tag(metric)
                                }
                            }
                            .pickerStyle(.segmented)
                            .controlSize(.small)
                            .labelsHidden()
                            .frame(
                                width: Self.metricPickerWidth,
                                height: Self.metricPickerHeight,
                                alignment: .trailing)
                            .accessibilityLabel(L("Display mode"))
                        }
                    }
                    .frame(height: Self.metricPickerHeight)
                }

                let detail = self.detailContent(selectedDateKey: selectedDateKey, model: model)
                VStack(alignment: .leading, spacing: Self.detailSpacing) {
                    Text(detail.primary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: Self.detailPrimaryLineHeight, alignment: .leading)
                    if detailLayout.viewportRowCount > 0 {
                        ScrollViewReader { detailProxy in
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
                                                        rowHeight: detailLayout.rowHeight))
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
                                        .frame(height: detailLayout.rowHeight, alignment: .leading)
                                    }
                                }
                            }
                            .scrollIndicators(
                                Self.detailRowsNeedScrolling(itemCount: detail.rows.count) ? .visible : .hidden)
                            .onChange(of: selectedDateKey) { _, _ in
                                if let firstID = detail.rows.first?.id {
                                    detailProxy.scrollTo(firstID, anchor: .top)
                                }
                            }
                        }
                        .frame(
                            height: Self.detailRowsViewportHeight(
                                rowCount: detailLayout.viewportRowCount,
                                rowHeight: detailLayout.rowHeight),
                            alignment: .topLeading)

                        if detailLayout.hasOverflow {
                            Text(Self.detailOverflowHint(itemCount: detail.rows.count) ?? " ")
                                .font(.caption2)
                                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                                .frame(height: Self.detailHintHeight, alignment: .leading)
                                .accessibilityHidden(!Self.detailRowsNeedScrolling(itemCount: detail.rows.count))
                        }
                    }
                }
                .frame(height: detailHeight, alignment: .topLeading)
            }

            if self.totalCostUSD != nil || incompleteCount > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(
                        format: incompleteCount > 0 ? L("Est. subtotal (%@): %@") : L("Est. total (%@): %@"),
                        self.windowLabel,
                        self.totalCostUSD.map(self.costString) ?? "—")
                        + UsageFormatter.incompleteUsageSuffix(incompleteCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(height: Self.detailPrimaryLineHeight, alignment: .leading)
                    if let disclaimer = UsageFormatter.incompleteUsageNote(incompleteCount)
                        ?? Self.estimateDisclaimer(provider: self.provider)
                    {
                        Text(disclaimer)
                            .help(disclaimer)
                            .font(.caption2)
                            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }

            if !self.projects.isEmpty {
                VStack(alignment: .leading, spacing: Self.projectRowSpacing) {
                    Text(L("Projects"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(height: Self.detailPrimaryLineHeight, alignment: .leading)
                    ForEach(
                        Array(self.projects.prefix(Self.maxVisibleProjectRows).enumerated()),
                        id: \.element.projectRowID)
                    { index, project in
                        let visibleSources = Self.visibleProjectSources(project)
                        VStack(alignment: .leading, spacing: Self.projectSourceSpacing) {
                            self.projectParentRow(project, ordinal: index + 1)
                            if !visibleSources.isEmpty {
                                ForEach(
                                    Array(visibleSources.prefix(Self.maxVisibleProjectSourceRows).enumerated()),
                                    id: \.element.sourceRowID)
                                { sourceIndex, source in
                                    self.projectSourceRow(source, ordinal: sourceIndex + 1)
                                }
                                let hiddenSourceCount = visibleSources.count - Self.maxVisibleProjectSourceRows
                                if hiddenSourceCount > 0 {
                                    Text(L("+ %d more", hiddenSourceCount))
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
        .padding(.top, 6)
        .frame(minWidth: self.width, maxWidth: .infinity, alignment: .top)
        .onChange(of: activeMetric) { _, newMetric in
            self.onMetricChanged?(newMetric)
        }
    }

    static func estimateDisclaimer(provider: UsageProvider) -> String? {
        guard let hint = ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.chartEstimateDisclaimer else {
            return nil
        }
        return switch hint {
        case let .localized(key): L(key)
        case .estimate: UsageFormatter.costEstimateHint(provider: provider)
        case let .literal(text): L(text)
        }
    }

    private struct Model {
        let points: [Point]
        let pointsByDateKey: [String: Point]
        let entriesByDateKey: [String: DailyEntry]
        let dateKeys: [(key: String, date: Date)]
        let axisDates: [Date]
        let barColor: Color
        let peakKey: String?
        let maxValue: Double
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
    private static let metricPickerHeight: CGFloat = 22
    private static let metricPickerWidth: CGFloat = 132
    private static let outerSpacing: CGFloat = 10
    private static let projectRowHeight: CGFloat = 31
    private static let projectRowSpacing: CGFloat = 5
    private static let maxVisibleProjectRows = 5
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
                Text(L("Conversations (%@)", self.windowLabel))
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
        let identity = CostHistoryIdentity(
            sessionID: session.sessionID, title: session.title, hidePersonalInfo: self.hidePersonalInfo)
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(identity.name)
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
        .help(L("Session %@", Self.shortSessionID(session.sessionID)))
        .accessibilityElement(children: .combine)
    }

    nonisolated static func shortSessionID(_ sessionID: String) -> String {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 12 else { return trimmed }
        return "\(trimmed.prefix(4))...\(trimmed.suffix(8))"
    }

    private static func sessionUsageLine(_ session: CostUsageSessionBreakdown) -> String {
        let modelLabel = Self.sessionModelLabel(session.modelBreakdowns.map(\.modelName))
        let input = session.inputTokens.map(UsageFormatter.tokenCountString) ?? "—"
        let cached = session.cachedInputTokens.map(UsageFormatter.tokenCountString) ?? "—"
        let output = session.outputTokens.map(UsageFormatter.tokenCountString) ?? "—"
        return "\(modelLabel) · \(input) input · \(cached) cached · \(output) output"
    }

    static func sessionModelLabel(_ models: [String]) -> String {
        let labels = models.map(UsageFormatter.modelDisplayName)
        return if labels.isEmpty {
            "Unknown model"
        } else if labels.count == 1 {
            labels[0]
        } else {
            "\(labels[0]) +\(labels.count - 1)"
        }
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

    /// Y-axis tick values for the cost chart: 0, mid, max when the range is at
    /// $1 or more; 0 and max for smaller ranges; empty for flat/no data so the
    /// axis renders no labels.
    private static func yAxisTickValues(maxCostUSD: Double) -> [Double] {
        guard maxCostUSD > 0 else { return [] }
        if maxCostUSD < 1.0 {
            return [0, maxCostUSD]
        }
        return [0, maxCostUSD / 2, maxCostUSD]
    }

    private static func yAxisTickValues(maxValue: Double, metric: ChartMetric) -> [Double] {
        switch metric {
        case .tokens:
            guard maxValue > 0 else { return [] }
            return maxValue < 2 ? [0, maxValue] : [0, maxValue / 2, maxValue]
        case .cost:
            return self.yAxisTickValues(maxCostUSD: maxValue)
        }
    }

    private static func makeModel(
        provider: UsageProvider,
        daily: [DailyEntry],
        metric: ChartMetric) -> Model
    {
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
        var maxValue: Double = 0
        for entry in sorted {
            guard let (value, date) = self.chartPointInput(for: entry, provider: provider, metric: metric) else {
                continue
            }
            let point = Point(
                date: date,
                value: value,
                costUSD: entry.costUSD.flatMap { $0 >= 0 ? $0 : nil },
                totalTokens: entry.totalTokens.flatMap { $0 >= 0 ? $0 : nil },
                requestCount: entry.requestCount,
                incompleteRequestCount: entry.incompleteRequestCount)
            points.append(point)
            pointsByKey[entry.date] = point
            entriesByKey[entry.date] = entry
            dateKeys.append((entry.date, date))
            if let cur = peak {
                if value > cur.value {
                    peak = (entry.date, value)
                }
            } else {
                peak = (entry.date, value)
            }
            maxValue = max(maxValue, value)
        }

        let axisDates: [Date] = {
            guard let first = dateKeys.first?.date, let last = dateKeys.last?.date else { return [] }
            if Calendar.current.isDate(first, inSameDayAs: last) {
                return [first]
            }
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
            peakKey: maxValue > 0 ? peak?.key : nil,
            maxValue: maxValue)
    }

    private static func barColor(for provider: UsageProvider) -> Color {
        let color = ProviderAccentPalette.color(for: provider)
        return Color(red: color.red, green: color.green, blue: color.blue)
    }

    private static func dateFromDayKey(
        _ key: String,
        provider: UsageProvider,
        calendar sourceCalendar: Calendar = .autoupdatingCurrent) -> Date?
    {
        let bytes = Array(key.utf8)
        let digitIndices = [0, 1, 2, 3, 5, 6, 8, 9]
        guard bytes.count == 10,
              bytes[4] == 45,
              bytes[7] == 45,
              digitIndices.allSatisfy({ (48...57).contains(bytes[$0]) })
        else { return nil }

        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }

        let displayCalendar = self.gregorianCalendar(timeZone: sourceCalendar.timeZone)
        let bucketCalendar = self.bucketCalendar(provider: provider, displayCalendar: displayCalendar)
        guard let date = bucketCalendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return nil
        }
        guard bucketCalendar.dateComponents([.year, .month, .day], from: date) == DateComponents(
            year: year,
            month: month,
            day: day)
        else { return nil }
        return displayCalendar.startOfDay(for: date)
    }

    private static func chartPointInput(
        for entry: DailyEntry,
        provider: UsageProvider,
        metric: ChartMetric) -> (value: Double, date: Date)?
    {
        if metric == .cost,
           ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.presentation == .tokensOnly
        {
            return nil
        }
        let value: Double? = switch metric {
        case .tokens:
            entry.totalTokens.flatMap { $0 >= 0 ? Double($0) : nil }
        case .cost:
            entry.costUSD.flatMap { $0 >= 0 ? $0 : nil }
        }
        // An incomplete-only day keeps a selectable marker, not a fabricated zero total.
        guard let value = value ?? (entry.incompleteRequestCount > 0 ? 0 : nil) else { return nil }
        guard let date = self.dateFromDayKey(entry.date, provider: provider) else { return nil }
        return (value, date)
    }

    private static func availableMetrics(provider: UsageProvider, daily: [DailyEntry]) -> [ChartMetric] {
        ChartMetric.allCases.filter { metric in
            daily.contains { self.chartPointInput(for: $0, provider: provider, metric: metric) != nil }
        }
    }

    private static func detailLayout(entry: DailyEntry?) -> DetailLayout {
        let breakdowns = entry.map(self.displayBreakdownItems) ?? []
        return DetailLayout(
            viewportRowCount: self.detailViewportRowCount(itemCount: breakdowns.count),
            hasOverflow: self.detailRowsNeedScrolling(itemCount: breakdowns.count),
            rowHeight: breakdowns.contains(where: self.hasModeSubtitle)
                ? self.expandedDetailRowHeight : self.compactDetailRowHeight)
    }

    /// Extra room needed to show any selectable day without moving a constrained native menu.
    static func maximumDetailHeightGrowth(provider: UsageProvider, daily: [DailyEntry]) -> CGFloat {
        let model = self.makeModel(provider: provider, daily: daily, metric: self.defaultMetric(
            provider: provider, daily: daily))
        let initialEntry = self.defaultSelectedDateKey(model: model).flatMap { model.entriesByDateKey[$0] }
        let maximumHeight = daily.compactMap { entry -> CGFloat? in
            guard ChartMetric.allCases.contains(where: {
                self.chartPointInput(for: entry, provider: provider, metric: $0) != nil
            }) else { return nil }
            return self.detailHeight(entry: entry)
        }.max() ?? 0
        return max(0, maximumHeight - self.detailHeight(entry: initialEntry))
    }

    private static func gregorianCalendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func bucketCalendar(provider: UsageProvider, displayCalendar: Calendar) -> Calendar {
        // Provider-specific by design: Mistral uses UTC day buckets; Codex alone defaults to exact local tokens.
        guard provider == .mistral else { return displayCalendar }
        // Mistral day keys are UTC buckets; map their boundary into the matching local display day.
        return self.gregorianCalendar(timeZone: TimeZone(secondsFromGMT: 0) ?? .gmt)
    }

    private static func defaultMetric(provider: UsageProvider, daily: [DailyEntry]) -> ChartMetric {
        if ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.presentation == .tokensOnly {
            return .tokens
        }
        let available = self.availableMetrics(provider: provider, daily: daily)
        // Provider-specific by design: Codex exposes exact local token totals, so its chart defaults to tokens.
        if provider == .codex, available.contains(.tokens) {
            return .tokens
        }
        if available.contains(.cost) {
            return .cost
        }
        return available.first ?? .cost
    }

    private static func showsHistoryRefreshing(
        provider: UsageProvider,
        metric: ChartMetric,
        historyCoverageIsEstablished: Bool) -> Bool
    {
        // Provider-specific by design: only Codex exposes incremental local-history coverage for token scans.
        provider == .codex && metric == .tokens && !historyCoverageIsEstablished
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
        guard let index = model.dateKeys.firstIndex(where: { $0.key == key }) else { return nil }
        guard let geometry = self.hoverGeometry(model: model, proxy: proxy, geo: geo) else { return nil }
        return geometry.bars[index].frame
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

        guard let geometry = self.hoverGeometry(model: model, proxy: proxy, geo: geo),
              let selection = ChartBarHoverSelection.selection(
                  at: location,
                  plotFrame: geometry.plotFrame,
                  bars: geometry.bars)
        else { return }
        let key = model.dateKeys[selection.index].key

        if self.selectedDateKey != key {
            self.updateDetails(from: self.selectedEntry(in: model), to: model.entriesByDateKey[key]) {
                self.selectedDateKey = key
            }
        }
    }

    private func updateMetric(_ metric: ChartMetric) {
        guard self.metric != metric else { return }
        let oldModel = Self.makeModel(provider: self.provider, daily: self.daily, metric: self.metric)
        let newModel = Self.makeModel(provider: self.provider, daily: self.daily, metric: metric)
        self.updateDetails(from: self.selectedEntry(in: oldModel), to: self.selectedEntry(in: newModel)) {
            self.metric = metric
        }
    }

    private func selectedEntry(in model: Model) -> DailyEntry? {
        let key = self.selectedDateKey.flatMap { model.pointsByDateKey[$0] == nil ? nil : $0 }
            ?? Self.defaultSelectedDateKey(model: model)
        return key.flatMap { model.entriesByDateKey[$0] }
    }

    private func updateDetails(
        from oldEntry: DailyEntry?,
        to newEntry: DailyEntry?,
        update: @escaping @MainActor () -> Void)
    {
        let applyContent: @MainActor () -> Void = {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { update() }
        }
        let delta = Self.detailHeight(entry: newEntry) - Self.detailHeight(entry: oldEntry)
        if delta != 0, let onDetailHeightChanged = self.onDetailHeightChanged {
            // The host makes room before SwiftUI lays out the selected day's larger breakdown.
            onDetailHeightChanged(delta, applyContent)
        } else {
            applyContent()
        }
    }

    private static func detailHeight(entry: DailyEntry?) -> CGFloat {
        let layout = self.detailLayout(entry: entry)
        return self.detailBlockHeight(
            rowCount: layout.viewportRowCount, hasOverflow: layout.hasOverflow, rowHeight: layout.rowHeight)
    }

    private func hoverGeometry(
        model: Model,
        proxy: ChartProxy,
        geo: GeometryProxy) -> (plotFrame: CGRect, bars: [ChartBarHoverSelection.Bar])?
    {
        guard let plotAnchor = proxy.plotFrame else { return nil }
        let plotFrame = geo[plotAnchor]
        guard let bars = ChartBarHoverSelection.calendarDayBars(
            dates: model.dateKeys.map(\.date),
            plotFrame: plotFrame,
            position: { proxy.position(forX: $0) })
        else { return nil }
        return (plotFrame, bars)
    }

    private func projectSummary(_ project: CostUsageProjectBreakdown) -> String {
        let cost = project.totalCostUSD
            .map { self.costString($0) } ?? "—"
        guard let totalTokens = project.totalTokens else { return cost }
        return "\(cost) · \(L("%@ tokens", UsageFormatter.tokenCountString(totalTokens)))"
    }

    private func projectParentRow(_ project: CostUsageProjectBreakdown, ordinal: Int) -> some View {
        let identity = Self.projectIdentity(project, ordinal: ordinal, hidePersonalInfo: self.hidePersonalInfo)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Text(identity.name)
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
            if let path = identity.path {
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(height: Self.projectRowHeight, alignment: .leading)
    }

    private func projectSourceRow(_ source: CostUsageProjectSourceBreakdown, ordinal: Int) -> some View {
        let identity = Self.sourceIdentity(source, ordinal: ordinal, hidePersonalInfo: self.hidePersonalInfo)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(identity.name)
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
            if let path = identity.path {
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

    private func detailContent(selectedDateKey: String?, model: Model) -> DetailContent {
        guard let key = selectedDateKey,
              let point = model.pointsByDateKey[key]
        else {
            return DetailContent(primary: L("Hover a bar for details"), rows: [])
        }

        let dayLabel = point.date.formatted(.dateTime.month(.abbreviated).day())
        var parts: [String] = []
        if let cost = point.costUSD {
            parts.append(self.costString(cost))
        }
        if let tokens = point.totalTokens {
            parts.append("\(UsageFormatter.tokenCountString(tokens)) tokens")
        }
        if let requests = point.requestCount {
            parts.append("\(UsageFormatter.tokenCountString(requests)) requests")
        }
        if parts.isEmpty { parts.append("—") }
        let primary = "\(dayLabel): \(parts.joined(separator: " · "))"
            + UsageFormatter.incompleteUsageSuffix(point.incompleteRequestCount)
        return DetailContent(
            primary: primary, rows: self.breakdownRows(entry: model.entriesByDateKey[key], barColor: model.barColor))
    }

    func breakdownRows(entry: DailyEntry?, barColor: Color) -> [DetailRow] {
        guard let entry else { return [] }
        return Self.displayBreakdownItems(entry)
            .enumerated()
            .map { index, item in
                DetailRow(
                    id: "\(item.modelName)-\(index)",
                    title: UsageFormatter.modelDisplayName(item.modelName),
                    subtitle: entry.modelBreakdowns?.isEmpty == false ? self.modelBreakdownTotalSubtitle(item) : nil,
                    modeSubtitle: self.modelBreakdownModeSubtitle(item),
                    accentColor: barColor.opacity(Self.breakdownAccentOpacity(for: index)))
            }
    }

    private static func displayBreakdownItems(_ entry: DailyEntry) -> [CostUsageDailyReport.ModelBreakdown] {
        if let breakdown = entry.modelBreakdowns, !breakdown.isEmpty { return self.orderedBreakdownItems(breakdown) }
        // Names are display-only; the source has not supplied per-model token or cost totals.
        let names = Set((entry.modelsUsed ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        return names.filter { !$0.isEmpty }.sorted().map {
            CostUsageDailyReport.ModelBreakdown(modelName: $0, costUSD: nil, totalTokens: nil)
        }
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
        let detail = UsageFormatter.modelCostDetail(
            item.modelName,
            costUSD: item.costUSD.map { $0 * self.costMultiplier },
            totalTokens: item.totalTokens,
            currencyCode: self.currencyCode)
        guard (item.incompleteRequestCount ?? 0) > 0 else { return detail }
        return (detail ?? "—") + UsageFormatter.incompleteUsageSuffix(item.incompleteRequestCount ?? 0)
    }

    private func modelBreakdownModeSubtitle(_ item: CostUsageDailyReport.ModelBreakdown) -> String? {
        let parts = [
            (L("Std"), item.standardCostUSD, item.standardTokens),
            (L("Fast"), item.priorityCostUSD, item.priorityTokens),
        ].compactMap { label, cost, tokens in
            cost.map { value in
                "\(label) \(self.costString(value))"
                    + (tokens.map { " · \(UsageFormatter.tokenCountString($0))" } ?? "")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }

    private func costString(_ value: Double) -> String {
        Self.costString(value * self.costMultiplier, currencyCode: self.currencyCode)
    }

    private static func costString(_ value: Double, currencyCode: String) -> String {
        UsageFormatter.currencyString(value, currencyCode: currencyCode)
    }

    private static func yAxisCostString(_ value: Double, currencyCode: String) -> String {
        UsageFormatter.compactCurrencyString(value, currencyCode: currencyCode)
    }

    private static func yAxisTokenString(_ value: Double) -> String {
        UsageFormatter.tokenCountString(Int(value.rounded()))
    }

    private func yAxisString(_ value: Double, metric: ChartMetric) -> String {
        switch metric {
        case .tokens:
            Self.yAxisTokenString(value)
        case .cost:
            Self.yAxisCostString(value * self.costMultiplier, currencyCode: self.currencyCode)
        }
    }

    private static func breakdownAccentOpacity(for index: Int) -> Double {
        let opacity = 0.75 - (Double(index) * 0.12)
        return max(0.3, opacity)
    }
}

extension CostHistoryChartMenuView {
    static func projectIdentity(
        _ project: CostUsageProjectBreakdown,
        ordinal: Int,
        hidePersonalInfo: Bool) -> CostHistoryIdentity
    {
        CostHistoryIdentity(
            name: project.name,
            path: project.path,
            placeholder: L("Project %d", ordinal),
            hidePersonalInfo: hidePersonalInfo)
    }

    static func sourceIdentity(
        _ source: CostUsageProjectSourceBreakdown,
        ordinal: Int,
        hidePersonalInfo: Bool) -> CostHistoryIdentity
    {
        CostHistoryIdentity(
            name: source.name,
            path: source.path,
            placeholder: L("Source %d", ordinal),
            hidePersonalInfo: hidePersonalInfo)
    }

    struct RenderFingerprint: Equatable {
        let hidePersonalInfo: Bool
        let currencyCode: String
        let costMultiplierBitPattern: UInt64
        let historyDays: Int
        let historyCoverageIsEstablished: Bool
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
        let incompleteRequestCount: Int?
        let standardCostBitPattern: UInt64?
        let priorityCostBitPattern: UInt64?
        let standardTokens: Int?
        let priorityTokens: Int?

        init(_ item: CostUsageDailyReport.ModelBreakdown) {
            self.modelName = item.modelName
            self.costBitPattern = item.costUSD.map(\.bitPattern)
            self.totalTokens = item.totalTokens
            self.incompleteRequestCount = item.incompleteRequestCount
            self.standardCostBitPattern = item.standardCostUSD.map(\.bitPattern)
            self.priorityCostBitPattern = item.priorityCostUSD.map(\.bitPattern)
            self.standardTokens = item.standardCostUSD == nil ? nil : item.standardTokens
            self.priorityTokens = item.priorityCostUSD == nil ? nil : item.priorityTokens
        }
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
        let name: String
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
        provider: UsageProvider,
        hidePersonalInfo: Bool = false,
        displayCurrencyCode: String? = nil,
        displayCostMultiplier: Double = 1.0) -> RenderFingerprint
    {
        let projects = provider == .codex ? snapshot.projects : []
        let sessions = provider == .codex ? snapshot.sessions : []
        return RenderFingerprint(
            hidePersonalInfo: hidePersonalInfo,
            currencyCode: displayCurrencyCode ?? snapshot.currencyCode,
            costMultiplierBitPattern: displayCostMultiplier.bitPattern,
            historyDays: snapshot.historyDays,
            historyCoverageIsEstablished: snapshot.historyCoverageIsEstablished,
            windowLabel: snapshot.historyLabel,
            totalCostBitPattern: snapshot.last30DaysCostUSD.map(\.bitPattern),
            hasDailyEntries: !snapshot.daily.isEmpty,
            daily: snapshot.daily
                .filter { entry in
                    self.availableMetrics(provider: provider, daily: [entry]).isEmpty == false
                }
                .sorted { $0.date < $1.date }
                .map(self.visibleDailyFingerprint),
            projects: Array(projects.prefix(self.maxVisibleProjectRows).enumerated()).map { index, project in
                let identity = self.projectIdentity(project, ordinal: index + 1, hidePersonalInfo: hidePersonalInfo)
                let visibleSources = self.visibleProjectSources(project)
                return VisibleProjectFingerprint(
                    name: identity.name,
                    path: identity.path,
                    totalTokens: project.totalTokens,
                    totalCostBitPattern: project.totalCostUSD.map(\.bitPattern),
                    visibleSourceCount: visibleSources.count,
                    sources: Array(visibleSources.prefix(self.maxVisibleProjectSourceRows).enumerated())
                        .map { sourceIndex, source in
                            let identity = self.sourceIdentity(
                                source,
                                ordinal: sourceIndex + 1,
                                hidePersonalInfo: hidePersonalInfo)
                            return VisibleSourceFingerprint(
                                name: identity.name,
                                path: identity.path,
                                totalTokens: source.totalTokens,
                                totalCostBitPattern: source.totalCostUSD.map(\.bitPattern))
                        })
            },
            sessions: sessions.map { session in
                VisibleSessionFingerprint(
                    sessionID: session.sessionID,
                    name: CostHistoryIdentity(
                        sessionID: session.sessionID, title: session.title, hidePersonalInfo: hidePersonalInfo).name,
                    lastActivityBitPattern: session.lastActivity.timeIntervalSince1970.bitPattern,
                    inputTokens: session.inputTokens,
                    cachedInputTokens: session.cachedInputTokens,
                    outputTokens: session.outputTokens,
                    totalTokens: session.totalTokens,
                    costBitPattern: session.costUSD.map(\.bitPattern),
                    models: session.modelBreakdowns.map(VisibleModelBreakdownFingerprint.init))
            })
    }

    private static func visibleDailyFingerprint(_ entry: DailyEntry) -> VisibleDailyFingerprint {
        VisibleDailyFingerprint(
            date: entry.date,
            totalTokens: entry.totalTokens,
            requestCount: entry.requestCount,
            costBitPattern: entry.costUSD.map(\.bitPattern),
            modelBreakdowns: self.displayBreakdownItems(entry).map(VisibleModelBreakdownFingerprint.init))
    }

    static func _defaultSelectedDateKeyForTesting(provider: UsageProvider, daily: [DailyEntry]) -> String? {
        self.defaultSelectedDateKey(model: self.makeModel(
            provider: provider,
            daily: daily,
            metric: self.defaultMetric(provider: provider, daily: daily)))
    }

    static func _showsHistoryRefreshingForTesting(
        provider: UsageProvider,
        metric: ChartMetric,
        historyCoverageIsEstablished: Bool) -> Bool
    {
        self.showsHistoryRefreshing(
            provider: provider,
            metric: metric,
            historyCoverageIsEstablished: historyCoverageIsEstablished)
    }

    static func _dateFromDayKeyForTesting(
        _ key: String,
        provider: UsageProvider,
        calendar: Calendar) -> Date?
    {
        self.dateFromDayKey(key, provider: provider, calendar: calendar)
    }

    static func _axisDatesForTesting(provider: UsageProvider, daily: [DailyEntry]) -> [Date] {
        self.makeModel(
            provider: provider,
            daily: daily,
            metric: self.defaultMetric(provider: provider, daily: daily)).axisDates
    }

    static func _yAxisTickValuesForTesting(maxCostUSD: Double) -> [Double] {
        self.yAxisTickValues(maxCostUSD: maxCostUSD)
    }

    static func _yAxisCostStringForTesting(_ value: Double, currencyCode: String = "USD") -> String {
        self.yAxisCostString(value, currencyCode: currencyCode)
    }

    static func _yAxisTokenStringForTesting(_ value: Double) -> String {
        self.yAxisTokenString(value)
    }

    static func _availableMetricsForTesting(
        provider: UsageProvider,
        daily: [DailyEntry]) -> [ChartMetric]
    {
        self.availableMetrics(provider: provider, daily: daily)
    }

    static func _defaultMetricForTesting(provider: UsageProvider, daily: [DailyEntry]) -> ChartMetric {
        self.defaultMetric(provider: provider, daily: daily)
    }

    static func _chartValuesForTesting(
        provider: UsageProvider,
        daily: [DailyEntry],
        metric: ChartMetric) -> [Double]
    {
        self.makeModel(provider: provider, daily: daily, metric: metric).points.map(\.value)
    }

    static func _detailViewportConfigurationForTesting(
        provider: UsageProvider,
        daily: [DailyEntry],
        metric: ChartMetric? = nil,
        selectedDateKey: String? = nil) -> (rowCount: Int, hasOverflow: Bool, rowHeight: CGFloat)
    {
        let model = self.makeModel(
            provider: provider,
            daily: daily,
            metric: metric ?? self.defaultMetric(provider: provider, daily: daily))
        let key = selectedDateKey.flatMap { model.pointsByDateKey[$0] == nil ? nil : $0 }
            ?? self.defaultSelectedDateKey(model: model)
        let detailLayout = self.detailLayout(entry: key.flatMap { model.entriesByDateKey[$0] })
        return (detailLayout.viewportRowCount, detailLayout.hasOverflow, detailLayout.rowHeight)
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
