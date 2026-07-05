import AppKit
import Charts
import CodexBarCore
import SwiftUI

@MainActor
struct DeepSeekUsageSummaryChartMenuView: View {
    private struct Point: Identifiable {
        let id: String
        let dateKey: String
        let date: Date
        let totalTokens: Int
        let cost: Double?
        let cacheHitPercent: Double?
        let day: DeepSeekDailyUsage
    }

    private struct DetailRow: Identifiable {
        let id: String
        let title: String
        let accentColor: Color
    }

    private struct TokenBreakdownLine: Identifiable {
        let id: String
        let title: String
        let value: String
        let swatchColor: Color
    }

    private struct DetailPanel {
        let placeholder: String?
        let dateKey: String?
        let headerTokens: String?
        let breakdownLines: [TokenBreakdownLine]
        let requestsText: String?
        let cacheHitText: String?
        let modelRows: [DetailRow]

        var hasContent: Bool {
            self.placeholder == nil && self.dateKey != nil
        }
    }

    private struct KPI: Identifiable {
        let id: String
        let title: String
        let value: String
    }

    private struct Model {
        let points: [Point]
        let pointsByDateKey: [String: Point]
        let axisDates: [Date]
        let barColor: Color
        let prefersCostTrend: Bool
    }

    private let usage: DeepSeekUsageSummary
    private let width: CGFloat
    private let showsSummaryKPIs: Bool
    private let onHeightChange: ((CGFloat) -> Void)?
    @State private var selectedDateKey: String?
    @State private var selectedModelID: String?
    @State private var windowDays: WindowDays = .seven

    private enum WindowDays: Int, CaseIterable {
        case seven = 7
        case thirty = 30
    }

    init(
        usage: DeepSeekUsageSummary,
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
        let selectedPoint = selectedDateKey.flatMap { model.pointsByDateKey[$0] }
        let selectedModelUsage = self.effectiveSelectedModelUsage(point: selectedPoint)
        let detail = self.detailContent(selectedDateKey: selectedDateKey, model: model)

        VStack(alignment: .leading, spacing: Self.outerSpacing) {
            if self.showsSummaryKPIs {
                self.kpiGrid(Self.summaryKPIs(usage: self.usage, selectedModel: selectedModelUsage))
            } else {
                self.kpiGrid(Self.windowKPIs(
                    usage: self.usage,
                    windowDays: self.windowDays,
                    selectedModel: selectedModelUsage))
            }

            self.trendHeaderSection

            if model.points.isEmpty {
                Text(L("No data available"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(model.points) { point in
                        if model.prefersCostTrend, let cost = point.cost {
                            BarMark(
                                x: .value(L("Day"), point.date, unit: .day),
                                y: .value(L("Cost"), max(0, cost)))
                                .foregroundStyle(model.barColor)
                        } else {
                            BarMark(
                                x: .value(L("Day"), point.date, unit: .day),
                                y: .value(L("tokens"), point.totalTokens))
                                .foregroundStyle(model.barColor)
                        }
                    }
                }
                .chartYAxis(.hidden)
                .chartXAxis(.hidden)
                .chartLegend(.hidden)
                .frame(height: Self.chartHeight)
                .accessibilityLabel(
                    self.windowDays == .seven
                        ? (model.prefersCostTrend
                            ? L("DeepSeek 7 day cost trend")
                            : L("DeepSeek 7 day token usage trend"))
                        : (model.prefersCostTrend
                            ? L("DeepSeek 30 day cost trend")
                            : L("DeepSeek 30 day token usage trend")))
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
                    if let placeholder = detail.placeholder {
                        Text(placeholder)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(height: Self.detailPlaceholderHeight, alignment: .leading)
                    } else if detail.hasContent {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(detail.dateKey ?? "")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(detail.headerTokens ?? "")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(height: Self.detailHeaderHeight, alignment: .leading)

                        if detail.modelRows.count > 1 {
                            self.modelPickerRows(
                                rows: detail.modelRows,
                                selectedModelID: selectedModelUsage?.model)
                        } else if let modelName = detail.modelRows.first?.title {
                            Text(modelName)
                                .font(.caption2)
                                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                                .lineLimit(1)
                                .frame(height: Self.modelNameLineHeight, alignment: .leading)
                        }

                        VStack(alignment: .leading, spacing: Self.detailSpacing) {
                            ForEach(detail.breakdownLines) { line in
                                HStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .fill(line.swatchColor)
                                        .frame(width: 10, height: 10)
                                    Text(line.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(line.value)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                }
                                .frame(height: Self.breakdownLineHeight, alignment: .leading)
                            }
                        }

                        HStack(spacing: 8) {
                            if let requests = detail.requestsText {
                                Text(String(format: L("%@ requests"), requests))
                            }
                            Spacer(minLength: 8)
                            if let cacheHit = detail.cacheHitText {
                                Text(String(format: L("Cache hit: %@"), cacheHit))
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                        .frame(height: Self.breakdownMetaHeight, alignment: .leading)
                    }
                }
                .frame(
                    height: Self.detailBlockHeight(panel: detail),
                    alignment: .topLeading)
            }

            Text(L("Reported by DeepSeek platform usage APIs; data may be delayed"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, Self.verticalPadding)
        .frame(minWidth: self.width, maxWidth: .infinity, alignment: .topLeading)
        .onChange(of: self.selectedDateKey) { _, _ in
            self.selectedModelID = nil
            self.notifyHeightChange(model: model)
        }
        .onChange(of: self.windowDays) { _, newValue in
            self.selectedDateKey = nil
            self.selectedModelID = nil
            let updatedModel = Self.makeModel(usage: self.usage, windowDays: newValue.rawValue)
            self.notifyHeightChange(model: updatedModel)
        }
        .onAppear {
            self.notifyHeightChange(model: model)
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
    private static let trendHeaderBlockHeight: CGFloat = 40
    private static let footerMinLineHeight: CGFloat = 36
    private static let footerBottomSlack: CGFloat = 4
    private static let detailPlaceholderHeight: CGFloat = 20
    private static let detailHeaderHeight: CGFloat = 18
    private static let modelNameLineHeight: CGFloat = 14
    private static let breakdownLineHeight: CGFloat = 18
    private static let breakdownMetaHeight: CGFloat = 16
    private static let modelPickerRowHeight: CGFloat = 28
    private static let detailSpacing: CGFloat = 6
    private static let chartHeight: CGFloat = 114
    private static let axisLabelAreaHeight: CGFloat = 16
    private static let outerSpacing: CGFloat = 10
    static let verticalPadding: CGFloat = 10
    private static let selectionBandColor = Color(nsColor: .labelColor).opacity(0.1)

    private func effectiveSelectedDateKey(model: Model) -> String? {
        self.selectedDateKey ?? model.points.last?.dateKey
    }

    private func effectiveSelectedModelUsage(point: Point?) -> DeepSeekDailyModelUsage? {
        guard let point, !point.day.models.isEmpty else { return nil }
        if let selectedModelID,
           let match = point.day.models.first(where: { $0.model == selectedModelID })
        {
            return match
        }
        return point.day.models.max(by: { $0.tokens < $1.tokens })
    }

    private func notifyHeightChange(model: Model) {
        guard let onHeightChange = self.onHeightChange else { return }
        let panel = self.detailContent(
            selectedDateKey: self.effectiveSelectedDateKey(model: model),
            model: model)
        onHeightChange(Self.totalCardHeight(
            panel: panel,
            hasChart: !model.points.isEmpty,
            width: self.width))
    }

    private func modelPickerRows(rows: [DetailRow], selectedModelID: String?) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Self.detailSpacing) {
                ForEach(rows) { row in
                    Button {
                        self.selectedModelID = row.id
                    } label: {
                        HStack(spacing: 8) {
                            Rectangle()
                                .fill(row.accentColor)
                                .frame(width: 2, height: Self.modelPickerRowHeight - 8)
                            Text(row.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(
                            row.id == selectedModelID
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .frame(height: Self.modelPickerRowHeight, alignment: .leading)
                }
            }
        }
        .scrollIndicators(Self.detailRowsNeedScrolling(itemCount: rows.count) ? .visible : .hidden)
        .frame(height: Self.detailRowsViewportHeight(rows: rows), alignment: .topLeading)
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

    private static func summaryKPIs(
        usage: DeepSeekUsageSummary,
        selectedModel: DeepSeekDailyModelUsage?) -> [KPI]
    {
        let symbol = usage.currencySymbol
        let todayCost = usage.todayCost.map { "\(symbol)\(String(format: "%.4f", max(0, $0)))" } ?? "—"
        let monthCost = usage.currentMonthCost.map { "\(symbol)\(String(format: "%.4f", max(0, $0)))" } ?? "—"
        return [
            KPI(id: "today-cost", title: L("Today cost"), value: todayCost),
            KPI(id: "month-cost", title: L("Month cost"), value: monthCost),
            KPI(
                id: "7d",
                title: L("7d tokens"),
                value: UsageFormatter.tokenCountString(usage.last7DaysTokens)),
            KPI(
                id: "cache",
                title: L("Cache hit"),
                value: Self.optionalPercentString(selectedModel?.cacheHitPercent)),
        ]
    }

    private static func windowKPIs(
        usage: DeepSeekUsageSummary,
        windowDays: WindowDays,
        selectedModel: DeepSeekDailyModelUsage?) -> [KPI]
    {
        let symbol = usage.currencySymbol
        let tokens = windowDays == .seven ? usage.last7DaysTokens : usage.last30DaysTokens
        let cost = windowDays == .seven ? usage.last7DaysCost : usage.last30DaysCost
        let spendTitle = windowDays == .seven ? L("7d spend") : L("30d spend")
        let tokenTitle = windowDays == .seven ? L("7d tokens") : L("30d tokens")
        let requests = selectedModel.map { "\($0.requestCount)" } ?? "—"
        return [
            KPI(id: "tokens", title: tokenTitle, value: UsageFormatter.tokenCountString(tokens)),
            KPI(
                id: "spend",
                title: spendTitle,
                value: cost.map { "\(symbol)\(String(format: "%.4f", max(0, $0)))" } ?? "—"),
            KPI(id: "requests", title: L("Requests"), value: requests),
            KPI(
                id: "cache",
                title: L("Cache hit"),
                value: Self.optionalPercentString(selectedModel?.cacheHitPercent)),
        ]
    }

    private func detailContent(selectedDateKey: String?, model: Model) -> DetailPanel {
        guard let key = selectedDateKey,
              let point = model.pointsByDateKey[key],
              let selected = self.effectiveSelectedModelUsage(point: point)
        else {
            return DetailPanel(
                placeholder: L("Hover a bar for details"),
                dateKey: nil,
                headerTokens: nil,
                breakdownLines: [],
                requestsText: nil,
                cacheHitText: nil,
                modelRows: [])
        }

        let modelRows = point.day.models.map { modelUsage in
            DetailRow(
                id: modelUsage.model,
                title: Self.shortModelName(modelUsage.model),
                accentColor: model.barColor)
        }
        return DetailPanel(
            placeholder: nil,
            dateKey: key,
            headerTokens: Self.detailedTokenString(selected.tokens),
            breakdownLines: Self.tokenBreakdownLines(for: selected, accentColor: model.barColor),
            requestsText: "\(selected.requestCount)",
            cacheHitText: Self.optionalPercentString(selected.cacheHitPercent),
            modelRows: modelRows)
    }

    private static func tokenBreakdownLines(
        for usage: DeepSeekDailyModelUsage,
        accentColor: Color) -> [TokenBreakdownLine]
    {
        [
            TokenBreakdownLine(
                id: "cache-hit",
                title: L("cache-hit input"),
                value: self.detailedTokenString(usage.cacheHitTokens),
                swatchColor: accentColor.opacity(0.35)),
            TokenBreakdownLine(
                id: "cache-miss",
                title: L("cache-miss input"),
                value: self.detailedTokenString(usage.cacheMissTokens),
                swatchColor: accentColor.opacity(0.65)),
            TokenBreakdownLine(
                id: "output",
                title: L("output"),
                value: self.detailedTokenString(usage.outputTokens),
                swatchColor: accentColor),
        ]
    }

    private static func detailedTokenString(_ value: Int) -> String {
        let count = value.formatted(.number.grouping(.automatic))
        return "\(count) \(L("tokens"))"
    }

    private static func makeModel(usage: DeepSeekUsageSummary, windowDays: Int) -> Model {
        let sorted = usage.trendDays(last: windowDays).compactMap { day -> Point? in
            guard let date = Self.date(from: day.date) else { return nil }
            return Point(
                id: day.date,
                dateKey: day.date,
                date: date,
                totalTokens: day.totalTokens,
                cost: day.cost,
                cacheHitPercent: day.cacheHitPercent,
                day: day)
        }
        let axisDates: [Date] = {
            guard let first = sorted.first?.date, let last = sorted.last?.date else { return [] }
            if Calendar.current.isDate(first, inSameDayAs: last) { return [first] }
            return [first, last]
        }()
        let pointsByDateKey = Dictionary(uniqueKeysWithValues: sorted.map { ($0.dateKey, $0) })
        let brand = ProviderDescriptorRegistry.descriptor(for: .deepseek).branding.color
        return Model(
            points: sorted,
            pointsByDateKey: pointsByDateKey,
            axisDates: axisDates,
            barColor: Color(red: brand.red, green: brand.green, blue: brand.blue),
            prefersCostTrend: usage.prefersCostTrend)
    }

    private static func totalCardHeight(panel: DetailPanel, hasChart: Bool, width: CGFloat) -> CGFloat {
        var height = self.verticalPadding * 2
        height += self.kpiGridHeight
        height += self.outerSpacing + self.trendHeaderBlockHeight
        if hasChart {
            height += self.chartHeight
            height += max(0, self.axisLabelAreaHeight - self.outerSpacing)
            height += self.outerSpacing
            height += self.detailBlockHeight(panel: panel)
        } else {
            height += 20
        }
        height += self.outerSpacing
        height += self.footerLineHeight(forWidth: width)
        height += self.footerBottomSlack
        return height
    }

    private static func footerLineHeight(forWidth width: CGFloat) -> CGFloat {
        let text = L("Reported by DeepSeek platform usage APIs; data may be delayed")
        let contentWidth = max(120, width - 32)
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        return max(self.footerMinLineHeight, ceil(rect.height))
    }

    private static func detailBlockHeight(panel: DetailPanel) -> CGFloat {
        guard panel.hasContent else { return self.detailPlaceholderHeight }
        var height = self.detailHeaderHeight + self.detailSpacing
        if panel.modelRows.count > 1 {
            height += self.detailSpacing + self.detailRowsViewportHeight(rows: panel.modelRows)
        } else if panel.modelRows.count == 1 {
            height += self.modelNameLineHeight + self.detailSpacing
        }
        height += CGFloat(panel.breakdownLines.count) * self.breakdownLineHeight
        height += CGFloat(max(panel.breakdownLines.count - 1, 0)) * self.detailSpacing
        height += self.detailSpacing + self.breakdownMetaHeight
        return height
    }

    private static func detailRowsViewportHeight(rows: [DetailRow]) -> CGFloat {
        let visibleRows = Array(rows.prefix(self.maxVisibleDetailLines))
        guard !visibleRows.isEmpty else { return 0 }
        let rowHeights = CGFloat(visibleRows.count) * self.modelPickerRowHeight
        let spacing = CGFloat(max(visibleRows.count - 1, 0)) * self.detailSpacing
        return rowHeights + spacing
    }

    private static func detailRowsNeedScrolling(itemCount: Int) -> Bool {
        itemCount > self.maxVisibleDetailLines
    }

    private static func optionalPercentString(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f%%", min(100, max(0, value)))
    }

    private static func shortModelName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 26 else { return trimmed }
        return String(trimmed.prefix(25)) + "…"
    }

    private static func date(from key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        return components.date
    }

    private func selectionBandRect(
        selectedDateKey: String?,
        model: Model,
        proxy: ChartProxy,
        geo: GeometryProxy) -> CGRect?
    {
        guard let key = selectedDateKey,
              let point = model.pointsByDateKey[key],
              let plotAnchor = proxy.plotFrame,
              let x = proxy.position(forX: point.date)
        else { return nil }

        let plotFrame = geo[plotAnchor]
        if model.points.count <= 1 {
            return CGRect(
                x: plotFrame.origin.x,
                y: plotFrame.origin.y,
                width: plotFrame.width,
                height: plotFrame.height)
        }

        let nextDayX = proxy.position(forX: ChartBarHoverSelection.nextCalendarDay(after: point.date)) ?? (x + 20)
        let barHalfWidth = Self.barHalfWidth(slotWidth: abs(nextDayX - x))
        let left = plotFrame.origin.x + x - barHalfWidth
        let right = plotFrame.origin.x + x + barHalfWidth
        return CGRect(x: left, y: plotFrame.origin.y, width: right - left, height: plotFrame.height)
    }

    private static func barHalfWidth(slotWidth: CGFloat) -> CGFloat {
        slotWidth * 0.25 + 2
    }

    private func updateSelection(
        location: CGPoint?,
        model: Model,
        proxy: ChartProxy,
        geo: GeometryProxy)
    {
        guard let location else { return }

        guard let plotAnchor = proxy.plotFrame else { return }
        let plotFrame = geo[plotAnchor]
        guard plotFrame.contains(location) else { return }

        let xInPlot = location.x - plotFrame.origin.x
        guard let date: Date = proxy.value(atX: xInPlot) else { return }
        guard let nearestPoint = model.points.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) ? true : false
        }) else { return }

        if model.points.count > 1,
           let barX = proxy.position(forX: nearestPoint.date)
        {
            let nextDayX = proxy.position(
                forX: ChartBarHoverSelection.nextCalendarDay(after: nearestPoint.date)) ?? (barX + 20)
            let barHalfWidth = Self.barHalfWidth(slotWidth: abs(nextDayX - barX))
            guard ChartBarHoverSelection.accepts(
                distanceFromBarCenter: abs(location.x - (plotFrame.origin.x + barX)),
                barHalfWidth: barHalfWidth,
                selectableCount: model.points.count)
            else { return }
        }

        let key = nearestPoint.dateKey
        if self.selectedDateKey != key {
            self.selectedDateKey = key
            self.selectedModelID = nil
            self.notifyHeightChange(model: model)
        }
    }
}

extension DeepSeekUsageSummaryChartMenuView {
    static func _barHalfWidthForTesting(slotWidth: CGFloat) -> CGFloat {
        self.barHalfWidth(slotWidth: slotWidth)
    }

    static func _makeModelSummaryForTesting(usage: DeepSeekUsageSummary, windowDays: Int) -> (
        pointCount: Int,
        prefersCostTrend: Bool,
        axisDateCount: Int)
    {
        let model = self.makeModel(usage: usage, windowDays: windowDays)
        return (model.points.count, model.prefersCostTrend, model.axisDates.count)
    }

    static func _detailRowsNeedScrollingForTesting(itemCount: Int) -> Bool {
        self.detailRowsNeedScrolling(itemCount: itemCount)
    }

    static func _totalCardHeightForTesting(rows: Int, hasChart: Bool, width: CGFloat = 310) -> CGFloat {
        let sampleModel = DeepSeekDailyModelUsage(
            model: "deepseek-chat",
            tokens: 1000,
            cost: 1,
            cacheHitTokens: 600,
            cacheMissTokens: 300,
            outputTokens: 100,
            requestCount: 3)
        let modelRows = (0..<rows).map { index in
            DetailRow(
                id: "model-\(index)",
                title: "model-\(index)",
                accentColor: .blue)
        }
        let panel = DetailPanel(
            placeholder: nil,
            dateKey: "2026-05-26",
            headerTokens: Self.detailedTokenString(sampleModel.tokens),
            breakdownLines: Self.tokenBreakdownLines(for: sampleModel, accentColor: .blue),
            requestsText: "\(sampleModel.requestCount)",
            cacheHitText: Self.optionalPercentString(sampleModel.cacheHitPercent),
            modelRows: modelRows)
        return self.totalCardHeight(panel: panel, hasChart: hasChart, width: width)
    }

    static func _tokenBreakdownLineCountForTesting() -> Int {
        let sampleModel = DeepSeekDailyModelUsage(
            model: "deepseek-chat",
            tokens: 783_013,
            cost: 1,
            cacheHitTokens: 653_056,
            cacheMissTokens: 123_806,
            outputTokens: 6151,
            requestCount: 21)
        return Self.tokenBreakdownLines(for: sampleModel, accentColor: .blue).count
    }

    static func _windowKPIValuesForTesting(
        usage: DeepSeekUsageSummary,
        windowDays: Int,
        selectedModel: DeepSeekDailyModelUsage?) -> [String]
    {
        let days = WindowDays(rawValue: windowDays) ?? .seven
        return Self.windowKPIs(usage: usage, windowDays: days, selectedModel: selectedModel)
            .map(\.value)
    }
}
