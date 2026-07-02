import Charts
import CodexBarCore
import SwiftUI

@MainActor
struct MiniMaxUsageSummaryChartMenuView: View {
    private struct Point: Identifiable {
        let id: String
        let dateKey: String
        let date: Date
        let totalTokens: Int
        let cacheHitPercent: Double?
        let day: MiniMaxUsageSummaryDay
    }

    private struct DetailRow: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let modeSubtitle: String?
        let accentColor: Color
    }

    private struct KPI: Identifiable {
        let id: String
        let title: String
        let value: String
    }

    private struct Model {
        let points: [Point]
        let pointsByDateKey: [String: Point]
        let dateKeys: [(key: String, date: Date)]
        let axisDates: [Date]
        let barColor: Color
    }

    private let usage: MiniMaxUsageSummary
    private let width: CGFloat
    private let showsSummaryKPIs: Bool
    private let onHeightChange: ((CGFloat) -> Void)?
    @State private var selectedDateKey: String?
    @State private var windowDays: WindowDays = .seven

    private enum WindowDays: Int, CaseIterable {
        case seven = 7
        case thirty = 30
    }

    init(
        usage: MiniMaxUsageSummary,
        showsSummaryKPIs: Bool = true,
        onHeightChange: ((CGFloat) -> Void)? = nil,
        width: CGFloat)
    {
        self.usage = usage
        self.showsSummaryKPIs = showsSummaryKPIs
        self.onHeightChange = onHeightChange
        self.width = width
    }

    var body: some View {
        let model = Self.makeModel(usage: self.usage, windowDays: self.windowDays.rawValue)
        let selectedDateKey = self.effectiveSelectedDateKey(model: model)
        let detail = self.detailContent(selectedDateKey: selectedDateKey, model: model)

        VStack(alignment: .leading, spacing: Self.outerSpacing) {
            if self.showsSummaryKPIs {
                self.kpiGrid(Self.summaryKPIs(usage: self.usage))
            } else {
                self.usageStatsSection(windowDays: self.windowDays)
            }

            self.trendHeaderSection

            if model.points.isEmpty {
                Text(L("No data available"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(model.points) { point in
                        BarMark(
                            x: .value(L("Day"), point.date, unit: .day),
                            y: .value(L("tokens"), point.totalTokens))
                            .foregroundStyle(model.barColor)
                    }
                }
                .chartYAxis(.hidden)
                .chartXAxis(.hidden)
                .chartLegend(.hidden)
                .frame(height: Self.chartHeight)
                .accessibilityLabel(
                    self.windowDays == .seven
                        ? L("MiniMax 7 day token usage trend")
                        : L("MiniMax 30 day token usage trend"))
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            if let rect = self.selectionBandRect(
                                selectedDateKey: selectedDateKey,
                                model: model,
                                proxy: proxy,
                                geo: geo)
                            {
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

                if model.axisDates.count == 2 {
                    HStack {
                        Text(model.axisDates[0], format: .dateTime.month(.abbreviated).day())
                        Spacer()
                        Text(model.axisDates[1], format: .dateTime.month(.abbreviated).day())
                    }
                    .font(.caption2)
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .frame(height: Self.axisLabelAreaHeight)
                    .padding(.top, -Self.outerSpacing)
                }

                VStack(alignment: .leading, spacing: Self.detailSpacing) {
                    Text(detail.primary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(height: Self.detailPrimaryLineHeight, alignment: .leading)

                    if !detail.rows.isEmpty {
                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: Self.detailSpacing) {
                                ForEach(detail.rows) { row in
                                    HStack(alignment: .top, spacing: 8) {
                                        Rectangle()
                                            .fill(row.accentColor)
                                            .frame(
                                                width: 2,
                                                height: Self.accentHeight(for: row))
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
                                    .frame(height: Self.detailRowHeight(for: row), alignment: .leading)
                                }
                            }
                        }
                        .scrollIndicators(
                            Self.detailRowsNeedScrolling(itemCount: detail.rows.count) ? .visible : .hidden)
                        .frame(
                            height: Self.detailRowsViewportHeight(rows: detail.rows),
                            alignment: .topLeading)
                        .id(selectedDateKey)
                    }
                }
                .frame(
                    height: Self.detailBlockHeight(rows: detail.rows),
                    alignment: .topLeading)
            }

            ForEach(Self.footerLines(usage: self.usage), id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(height: Self.footerLineHeight, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, Self.verticalPadding)
        .frame(minWidth: self.width, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: self.windowDays) { _, newValue in
            self.selectedDateKey = nil
            let updatedModel = Self.makeModel(usage: self.usage, windowDays: newValue.rawValue)
            self.notifyHeightChange(model: updatedModel)
        }
    }

    private var trendHeaderSection: some View {
        VStack(alignment: .leading, spacing: Self.trendHeaderSpacing) {
            Text(L("Usage trend"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            self.windowToggle
        }
        .frame(height: Self.trendHeaderBlockHeight, alignment: .topLeading)
    }

    private var windowToggle: some View {
        Picker(
            selection: Binding(
                get: { self.windowDays.rawValue },
                set: { self.windowDays = WindowDays(rawValue: $0) ?? .seven }))
        {
            Text(L("Last 7 days")).tag(WindowDays.seven.rawValue)
            Text(L("Last 30 days")).tag(WindowDays.thirty.rawValue)
        } label: {
            EmptyView()
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .accessibilityLabel(L("Usage trend"))
    }

    static let maxVisibleDetailLines = 4
    private static let kpiTitleLineHeight: CGFloat = 13
    private static let kpiValueLineHeight: CGFloat = 20
    private static let kpiCellInnerSpacing: CGFloat = 1
    private static let kpiRowHeight: CGFloat = 36
    private static let kpiGridRowSpacing: CGFloat = 6
    private static let kpiGridHeight: CGFloat = 78
    private static let trendHeaderSpacing: CGFloat = 6
    private static let trendHeaderTitleHeight: CGFloat = 14
    private static let trendHeaderPickerHeight: CGFloat = 24
    private static var trendHeaderBlockHeight: CGFloat {
        self.trendHeaderTitleHeight + self.trendHeaderSpacing + self.trendHeaderPickerHeight
    }

    private static let footerLineHeight: CGFloat = 28
    private static let detailPrimaryLineHeight: CGFloat = 32
    private static let detailTitleLineHeight: CGFloat = 16
    private static let detailSubtitleLineHeight: CGFloat = 13
    private static let compactDetailRowHeight: CGFloat = 36
    private static let expandedDetailRowHeight: CGFloat = 44
    private static let detailSpacing: CGFloat = 6
    private static let chartHeight: CGFloat = 114
    private static let axisLabelAreaHeight: CGFloat = 16
    private static let outerSpacing: CGFloat = 10
    static let verticalPadding: CGFloat = 10
    private static let selectionBandColor = Color(nsColor: .labelColor).opacity(0.1)

    private static func totalCardHeight(
        rows: [DetailRow],
        hasChart: Bool) -> CGFloat
    {
        var height = self.verticalPadding * 2
        height += self.kpiGridHeight
        height += self.outerSpacing + self.trendHeaderBlockHeight
        if hasChart {
            height += self.chartHeight
            height += self.axisLabelAreaHeight
            height += self.outerSpacing
            height += self.detailBlockHeight(rows: rows)
        } else {
            height += 20
        }
        height += self.outerSpacing
        height += self.footerLineHeight
        return height
    }

    private static func detailBlockHeight(rows: [DetailRow]) -> CGFloat {
        guard !rows.isEmpty else { return self.detailPrimaryLineHeight }
        return self.detailPrimaryLineHeight + self.detailSpacing + self.detailRowsViewportHeight(rows: rows)
    }

    private static func detailRowsViewportHeight(rows: [DetailRow]) -> CGFloat {
        let visibleRows = Array(rows.prefix(self.maxVisibleDetailLines))
        guard !visibleRows.isEmpty else { return 0 }

        let rowHeights = visibleRows.reduce(CGFloat(0)) { total, row in
            total + self.detailRowHeight(for: row)
        }
        let spacing = CGFloat(max(visibleRows.count - 1, 0)) * self.detailSpacing
        return rowHeights + spacing
    }

    private static func detailRowHeight(for row: DetailRow) -> CGFloat {
        self.detailRowHeight(hasModeSubtitle: row.modeSubtitle != nil)
    }

    private static func detailRowHeight(hasModeSubtitle: Bool) -> CGFloat {
        hasModeSubtitle ? self.expandedDetailRowHeight : self.compactDetailRowHeight
    }

    private static func accentHeight(for row: DetailRow) -> CGFloat {
        row.subtitle == nil && row.modeSubtitle == nil ? 14 : self.detailRowHeight(for: row)
    }

    static func detailViewportRowCount(itemCount: Int) -> Int {
        min(max(itemCount, 0), self.maxVisibleDetailLines)
    }

    static func detailRowsNeedScrolling(itemCount: Int) -> Bool {
        itemCount > self.maxVisibleDetailLines
    }

    private func effectiveSelectedDateKey(model: Model) -> String? {
        self.selectedDateKey ?? model.dateKeys.last?.key
    }

    private func notifyHeightChange(model: Model) {
        guard let onHeightChange = self.onHeightChange else { return }
        let detail = self.detailContent(
            selectedDateKey: self.effectiveSelectedDateKey(model: model),
            model: model)
        onHeightChange(Self.totalCardHeight(
            rows: detail.rows,
            hasChart: !model.points.isEmpty))
    }

    private func usageStatsSection(windowDays: WindowDays) -> some View {
        self.kpiGrid(Self.usageStatsKPIs(usage: self.usage, windowDays: windowDays))
    }

    private static func usageStatsKPIs(usage: MiniMaxUsageSummary, windowDays: WindowDays) -> [KPI] {
        var kpis: [KPI] = []
        if let total = usage.totalTokenConsumed?.trimmingCharacters(in: .whitespacesAndNewlines),
           !total.isEmpty
        {
            kpis.append(KPI(id: "total", title: L("Total consumed"), value: total))
        }
        if let peak = self.peakDayTokens(usage: usage) {
            kpis.append(KPI(
                id: "peak",
                title: L("Daily peak"),
                value: self.minimaxTokenString(peak)))
        }
        if let activeDays = usage.activeDays {
            kpis.append(KPI(id: "active", title: L("Active days"), value: "\(activeDays)"))
        }
        if let spend = usage.projectedCostUSD(lastDays: windowDays.rawValue) {
            kpis.append(KPI(
                id: "spend",
                title: self.windowSpendTitle(windowDays: windowDays),
                value: UsageFormatter.usdString(spend)))
        }
        return kpis
    }

    private static func peakDayTokens(usage: MiniMaxUsageSummary) -> Int? {
        let dayPeak = usage.days.map(\.totalToken).max() ?? 0
        let trendPeak = usage.dailyTokenUsage.max() ?? 0
        let peak = max(dayPeak, trendPeak)
        return peak > 0 ? peak : nil
    }

    private func kpiGrid(_ kpis: [KPI]) -> some View {
        VStack(alignment: .leading, spacing: Self.kpiGridRowSpacing) {
            ForEach(Array(stride(from: 0, to: kpis.count, by: 2)), id: \.self) { rowStart in
                HStack(alignment: .top, spacing: 0) {
                    ForEach(kpis[rowStart..<min(rowStart + 2, kpis.count)]) { kpi in
                        self.kpiCell(kpi)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if kpis.count - rowStart == 1 {
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .frame(height: Self.kpiGridHeight, alignment: .topLeading)
    }

    private func kpiCell(_ kpi: KPI) -> some View {
        VStack(alignment: .leading, spacing: Self.kpiCellInnerSpacing) {
            Text(kpi.title)
                .font(.caption2)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: Self.kpiTitleLineHeight, alignment: .leading)
            Text(kpi.value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(height: Self.kpiValueLineHeight, alignment: .leading)
        }
        .frame(height: Self.kpiRowHeight, alignment: .topLeading)
    }

    private static func summaryKPIs(usage: MiniMaxUsageSummary) -> [KPI] {
        let latestTitle: String = {
            if let time = usage.lastUpdateTime?.trimmingCharacters(in: .whitespacesAndNewlines), !time.isEmpty {
                return String(format: L("%@ usage"), time)
            }
            return L("Latest usage")
        }()
        return [
            KPI(
                id: "latest",
                title: latestTitle,
                value: Self.minimaxTokenString(usage.latestSnapshotTokens)),
            KPI(
                id: "7d",
                title: L("7d tokens"),
                value: Self.minimaxTokenString(usage.last7DaysTokens)),
            KPI(
                id: "30d",
                title: L("30d tokens"),
                value: Self.minimaxTokenString(usage.last30DaysTokens)),
            KPI(
                id: "cache",
                title: L("Cache hit"),
                value: UsageFormatter.optionalPercentString(usage.snapshotDay?.cacheHitPercent)),
        ]
    }

    static func summaryKPIValues(usage: MiniMaxUsageSummary) -> [String] {
        self.summaryKPIs(usage: usage).map(\.value)
    }

    private static func footerLines(usage: MiniMaxUsageSummary) -> [String] {
        [L("Language models only; data may be delayed")]
    }

    private func detailContent(selectedDateKey: String?, model: Model) -> (primary: String, rows: [DetailRow]) {
        guard let key = selectedDateKey,
              let point = model.pointsByDateKey[key],
              let date = Self.date(from: key)
        else {
            return (L("Hover a bar for details"), [])
        }

        let dayLabel = date.formatted(.dateTime.month(.abbreviated).day())
        let primary = Self.dayDetailPrimary(dayLabel: dayLabel, point: point, usage: self.usage)
        return (primary, Self.detailRows(for: point, accentColor: model.barColor, usage: self.usage))
    }

    private static func windowSpendTitle(windowDays: WindowDays) -> String {
        switch windowDays {
        case .seven: L("7d spend")
        case .thirty: L("30d spend")
        }
    }

    private static func dayDetailPrimary(dayLabel: String, point: Point, usage: MiniMaxUsageSummary) -> String {
        let cacheText = UsageFormatter.optionalPercentString(point.cacheHitPercent)
        var parts = [
            "\(dayLabel): \(Self.minimaxTokenString(point.totalTokens)) \(L("tokens"))",
            String(format: L("Cache hit: %@"), cacheText),
        ]
        if let costUSD = usage.projectedCostUSD(for: point.day) {
            parts.append(UsageFormatter.usdString(costUSD))
        }
        return parts.joined(separator: " · ")
    }

    private static func makeModel(usage: MiniMaxUsageSummary, windowDays: Int) -> Model {
        let sorted = usage.trendDays(last: windowDays).compactMap { day -> Point? in
            guard let date = Self.date(from: day.date), day.totalToken >= 0 else { return nil }
            return Point(
                id: day.date,
                dateKey: day.date,
                date: date,
                totalTokens: day.totalToken,
                cacheHitPercent: day.cacheHitPercent,
                day: day)
        }
        let axisDates: [Date] = {
            guard let first = sorted.first?.date, let last = sorted.last?.date else { return [] }
            if Calendar.current.isDate(first, inSameDayAs: last) { return [first] }
            return [first, last]
        }()
        let pointsByDateKey = Dictionary(uniqueKeysWithValues: sorted.map { ($0.dateKey, $0) })
        let brand = ProviderDescriptorRegistry.descriptor(for: .minimax).branding.color
        return Model(
            points: sorted,
            pointsByDateKey: pointsByDateKey,
            dateKeys: sorted.map { ($0.dateKey, $0.date) },
            axisDates: axisDates,
            barColor: Color(red: brand.red, green: brand.green, blue: brand.blue))
    }

    private static func date(from key: String) -> Date? {
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

    private static func detailRows(
        for point: Point,
        accentColor: Color,
        usage: MiniMaxUsageSummary) -> [DetailRow]
    {
        let breakdownByModel = Dictionary(
            usage.projectedModelBreakdowns(for: point.day).map { ($0.modelName, $0) },
            uniquingKeysWith: { first, _ in first })
        if !point.day.models.isEmpty {
            return point.day.models
                .sorted { lhs, rhs in
                    if lhs.totalToken == rhs.totalToken { return lhs.model < rhs.model }
                    return lhs.totalToken > rhs.totalToken
                }
                .enumerated()
                .map { index, model in
                    let breakdown = breakdownByModel[model.model]
                    let subtitle = breakdown.flatMap {
                        UsageFormatter.modelCostDetail(
                            $0.modelName,
                            costUSD: $0.costUSD,
                            totalTokens: $0.totalTokens)
                    } ?? Self.modelTokenSubtitle(model)
                    return DetailRow(
                        id: "\(model.model)#\(index)",
                        title: Self.shortModelName(model.model),
                        subtitle: subtitle,
                        modeSubtitle:
                        "\(L("cache-hit input")): \(Self.minimaxTokenString(model.cacheReadToken)) · " +
                            "\(L("output")): \(Self.minimaxTokenString(model.outputToken))",
                        accentColor: accentColor.opacity(Self.breakdownAccentOpacity(for: index)))
                }
        }

        let cacheMiss = max(0, point.day.totalInputToken - point.day.totalCacheReadToken)
        let breakdown = breakdownByModel["Day totals"]
        let subtitle = breakdown.flatMap {
            UsageFormatter.modelCostDetail(
                $0.modelName,
                costUSD: $0.costUSD,
                totalTokens: $0.totalTokens)
        } ??
            "\(L("cache-hit input")): \(Self.minimaxTokenString(point.day.totalCacheReadToken)) · " +
            "\(L("cache-miss input")): \(Self.minimaxTokenString(cacheMiss))"
        return [
            DetailRow(
                id: "summary",
                title: L("Day totals"),
                subtitle: subtitle,
                modeSubtitle:
                "\(L("output")): \(Self.minimaxTokenString(point.day.totalOutputToken)) · " +
                    "\(L("Caches")): \(Self.minimaxTokenString(point.day.totalCacheCreateToken))",
                accentColor: accentColor),
        ]
    }

    private static func modelTokenSubtitle(_ model: MiniMaxUsageSummaryModel) -> String {
        let cacheText = UsageFormatter.optionalPercentString(model.cacheHitPercent)
        return "\(Self.minimaxTokenString(model.totalToken)) \(L("tokens")) · " +
            String(format: L("Cache hit: %@"), cacheText)
    }

    private static func breakdownAccentOpacity(for index: Int) -> Double {
        max(0.35, 1.0 - (Double(index) * 0.15))
    }

    private static func shortModelName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 26 else { return trimmed }
        return String(trimmed.prefix(25)) + "…"
    }

    private static func minimaxTokenString(_ value: Int) -> String {
        UsageFormatter.tokenCountString(value, fractionDigits: 2)
    }

    private func selectionBandRect(
        selectedDateKey: String?,
        model: Model,
        proxy: ChartProxy,
        geo: GeometryProxy) -> CGRect?
    {
        guard let key = selectedDateKey,
              let index = model.dateKeys.firstIndex(where: { $0.key == key }),
              let plotAnchor = proxy.plotFrame
        else { return nil }
        let plotFrame = geo[plotAnchor]
        let date = model.dateKeys[index].date
        guard let x = proxy.position(forX: date) else { return nil }
        let nextDayX = proxy.position(forX: ChartBarHoverSelection.nextCalendarDay(after: date)) ?? (x + 20)
        let slotWidth = abs(nextDayX - x)
        let halfWidth = slotWidth * 0.25 + 2
        return CGRect(
            x: plotFrame.origin.x + x - halfWidth,
            y: plotFrame.origin.y,
            width: halfWidth * 2,
            height: plotFrame.height)
    }

    private func updateSelection(
        location: CGPoint?,
        model: Model,
        proxy: ChartProxy,
        geo: GeometryProxy)
    {
        guard let location,
              let plotAnchor = proxy.plotFrame
        else { return }
        let plotFrame = geo[plotAnchor]
        guard plotFrame.contains(location) else { return }
        let xInPlot = location.x - plotFrame.origin.x
        guard let date: Date = proxy.value(atX: xInPlot) else { return }
        guard let nearest = self.nearestDateKey(to: date, model: model) else { return }

        if self.selectedDateKey != nearest {
            self.selectedDateKey = nearest
            self.notifyHeightChange(model: model)
        }
    }

    private func nearestDateKey(to date: Date, model: Model) -> String? {
        model.dateKeys.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        })?.key
    }
}

extension MiniMaxUsageSummaryChartMenuView {
    static func _dayDetailPrimaryForTesting(usage: MiniMaxUsageSummary, dateKey: String) -> String? {
        guard let day = usage.days.first(where: { $0.date == dateKey }),
              let date = Self.date(from: dateKey)
        else {
            return nil
        }
        let point = Point(
            id: day.date,
            dateKey: day.date,
            date: date,
            totalTokens: day.totalToken,
            cacheHitPercent: day.cacheHitPercent,
            day: day)
        let dayLabel = date.formatted(.dateTime.month(.abbreviated).day())
        return Self.dayDetailPrimary(dayLabel: dayLabel, point: point, usage: usage)
    }

    static func _detailRowCountForTesting(usage: MiniMaxUsageSummary, dateKey: String) -> Int {
        let view = Self(usage: usage, width: 320)
        let model = Self.makeModel(usage: usage, windowDays: 30)
        return view.detailContent(selectedDateKey: dateKey, model: model).rows.count
    }

    static func _detailViewportHeightForTesting(modeSubtitlePresence: [Bool]) -> CGFloat {
        let rows = modeSubtitlePresence.enumerated().map { index, hasModeSubtitle in
            DetailRow(
                id: "\(index)",
                title: "Row \(index)",
                subtitle: "Subtitle",
                modeSubtitle: hasModeSubtitle ? "Mode" : nil,
                accentColor: .blue)
        }
        return self.detailRowsViewportHeight(rows: rows)
    }

    static func _detailBlockHeightForTesting(modeSubtitlePresence: [Bool]) -> CGFloat {
        let rows = modeSubtitlePresence.enumerated().map { index, hasModeSubtitle in
            DetailRow(
                id: "\(index)",
                title: "Row \(index)",
                subtitle: "Subtitle",
                modeSubtitle: hasModeSubtitle ? "Mode" : nil,
                accentColor: .blue)
        }
        return self.detailBlockHeight(rows: rows)
    }

    static func _totalCardHeightForTesting(modeSubtitlePresence: [Bool], hasChart: Bool) -> CGFloat {
        let rows = modeSubtitlePresence.enumerated().map { index, hasModeSubtitle in
            DetailRow(
                id: "\(index)",
                title: "Row \(index)",
                subtitle: "Subtitle",
                modeSubtitle: hasModeSubtitle ? "Mode" : nil,
                accentColor: .blue)
        }
        return self.totalCardHeight(rows: rows, hasChart: hasChart)
    }
}
