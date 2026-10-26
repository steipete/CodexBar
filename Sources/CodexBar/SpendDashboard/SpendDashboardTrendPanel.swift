import AppKit
import Charts
import CodexBarCore
import SwiftUI

struct SpendDashboardTrendPanel: View {
    let group: SpendDashboardModel.CurrencyGroup
    @Binding var selection: SpendDashboardTrendSection
    var onSelectDay: ((Date) -> Void)?
    var onClearSelectedDay: (() -> Void)?
    @State private var focusedDay: Date?
    @State private var selectedSourceID: String?
    @State private var focusedInterval: DateInterval?

    var body: some View {
        let legendProviders = SpendTrendChartModel(
            group: self.group,
            section: self.activeSection,
            day: self.day,
            overviewInterval: self.focusedInterval).legendProviders(in: self.group)
        let sourceID = self.selectedSourceID.flatMap { id in legendProviders.contains { $0.id == id } ? id : nil }
        return SpendDashboardPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Text(self.activeSection == .hourly ? self.activeSection.title : L("Estimated spend"))
                        .font(.headline)
                    Spacer()
                    if !self.hourlyDays.isEmpty {
                        Picker(L("Usage & Spend"), selection: self.$selection) {
                            Text(SpendDashboardTrendSection.daily.pickerTitle).tag(SpendDashboardTrendSection.daily)
                            Text(SpendDashboardTrendSection.hourly.pickerTitle).tag(SpendDashboardTrendSection.hourly)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .frame(width: 140)
                        .accessibilityIdentifier("spend-dashboard-trend-picker")
                    }
                }
                if self.activeSection == .hourly, let day = self.day {
                    self.dayNavigation(day)
                } else {
                    HStack {
                        Text(self.scopeText).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if self.focusedInterval != nil {
                            Button(L("Overview")) { self.focusedInterval = nil }
                                .controlSize(.small).accessibilityIdentifier("spend-trend-back-overview")
                        }
                    }
                    Text(L("Click a bar to explore. Use the menu below for exact amounts."))
                        .font(.caption).foregroundStyle(.secondary)
                }

                SpendTrendChart(
                    group: self.group,
                    section: self.activeSection,
                    day: self.day,
                    sourceID: sourceID,
                    overviewInterval: self.focusedInterval,
                    onSelectDay: { day in
                        self.focusedDay = self.group.calendar.startOfDay(for: day)
                        self.selection = .hourly
                    },
                    onSelectInterval: { self.focusedInterval = $0 })
                    .id(self.chartIdentity(sourceID: sourceID))

                MenuBarLayoutChipFlowLayout(spacing: 8) {
                    self.legend(providers: legendProviders, selectedSourceID: sourceID)
                }
            }
        }
        .onChange(of: self.group.selectedDay) { _, selectedDay in
            self.focusedDay = selectedDay
            self.selection = selectedDay != nil && !self.hourlyDays.isEmpty ? .hourly : .daily
        }
        .onChange(of: self.group.chartDomain) { _, _ in self.focusedInterval = nil }
        .onChange(of: legendProviders.map(\.id)) { _, ids in
            if let selectedSourceID, !ids.contains(selectedSourceID) { self.selectedSourceID = nil }
        }
    }

    private func chartIdentity(sourceID: String?) -> String {
        "\(self.activeSection):\(self.day?.timeIntervalSince1970 ?? 0):"
            + "\(sourceID ?? "all"):\(self.group.chartDomain):"
            + "\(self.focusedInterval?.start.timeIntervalSince1970 ?? 0)"
    }

    private var scopeText: String {
        let scope = self.focusedInterval.map { $0.start...$0.end } ?? self.group.chartDomain
        let unit = SpendTrendChartModel.overviewUnit(in: scope, calendar: self.group.calendar)
        let grouping = unit == .month ? L("Monthly") : unit == .weekOfYear ? L("Weekly") : L("Daily")
        return "\(self.dateText(scope.lowerBound)) – "
            + "\(self.dateText(scope.upperBound.addingTimeInterval(-1))) · \(grouping)"
    }

    private var activeSection: SpendDashboardTrendSection {
        self.hourlyDays.isEmpty ? .daily : self.selection
    }

    private var hourlyDays: [Date] {
        SpendTrendChartModel.hourlyDays(self.group)
    }

    private var day: Date? {
        SpendTrendChartModel.focusedDay(self.focusedDay, group: self.group)
    }

    private func dayNavigation(_ day: Date) -> some View {
        let index = self.hourlyDays.firstIndex(of: day)
        return HStack(spacing: 8) {
            Button {
                self.focusedDay = self.hourlyDays[max(0, (index ?? 0) - 1)]
            } label: { Image(systemName: "chevron.left") }
                .disabled(index == nil || index == 0)
                .help(L("Previous day"))
                .accessibilityLabel(L("Previous day"))
                .accessibilityIdentifier("spend-trend-previous-day")
            Picker(L("Day"), selection: Binding(
                get: { day },
                set: { self.focusedDay = $0 }))
            {
                ForEach(self.hourlyDays, id: \.self) { date in
                    Text(self.dateText(date)).tag(date)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 180)
            .accessibilityIdentifier("spend-trend-day-picker")
            Button {
                self.focusedDay = self.hourlyDays[min(self.hourlyDays.count - 1, (index ?? 0) + 1)]
            } label: { Image(systemName: "chevron.right") }
                .disabled(index == nil || (index ?? 0) >= self.hourlyDays.count - 1)
                .help(L("Next day"))
                .accessibilityLabel(L("Next day"))
                .accessibilityIdentifier("spend-trend-next-day")
            Spacer()
            if let onClearSelectedDay, self.group.selectedDay != nil {
                Button(L("Clear")) {
                    self.selection = .daily
                    onClearSelectedDay()
                }
                .accessibilityIdentifier("spend-trend-clear-day")
            } else if let onSelectDay, self.group.selectedDay == nil {
                Button(L("Models for this day")) { onSelectDay(day) }
                    .accessibilityIdentifier("spend-trend-day-details")
            }
        }
        .controlSize(.small)
    }

    private func legend(providers: [SpendDashboardModel.ProviderRow], selectedSourceID: String?) -> some View {
        ForEach(providers) { provider in
            Button {
                self.selectedSourceID = self.selectedSourceID == provider.id ? nil : provider.id
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(Color(nsColor: SpendChartPalette.color(
                        sourceID: provider.id, provider: provider.provider, providers: self.group.providers)))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    SpendProviderIcon(
                        provider: provider.provider, sourceKind: provider.sourceKind, style: .brand)
                    Text(SpendChartPalette.label(provider, providers: self.group.providers))
                        .font(.callout)
                        .fixedSize()
                }
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(
                    selectedSourceID == provider.id ? Color.primary.opacity(0.07) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
                .opacity(selectedSourceID == nil || selectedSourceID == provider.id ? 1 : 0.6)
            }
            .buttonStyle(.plain)
            .help(L("Click to isolate a source. Click again to show all."))
            .accessibilityAddTraits(selectedSourceID == provider.id ? .isSelected : [])
            .accessibilityIdentifier("spend-trend-source-\(provider.id)")
        }
    }

    private func dateText(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(
            locale: codexBarLocalizedLocale(),
            calendar: self.group.calendar,
            timeZone: self.group.timeZone).year().month(.abbreviated).day())
    }
}

struct SpendTrendChart: View {
    let group: SpendDashboardModel.CurrencyGroup
    let section: SpendDashboardTrendSection
    let day: Date?
    let sourceID: String?
    var overviewInterval: DateInterval?
    var onSelectDay: ((Date) -> Void)?
    var onSelectInterval: ((DateInterval) -> Void)?
    @State private var inspectedDate: Date?
    @State private var pinnedDate: Date?

    private var model: SpendTrendChartModel {
        SpendTrendChartModel(
            group: self.group,
            section: self.section,
            day: self.day,
            sourceID: self.sourceID,
            overviewInterval: self.overviewInterval)
    }

    var body: some View {
        let model = self.model
        VStack(alignment: .leading, spacing: 10) {
            if self.section == .hourly {
                Text(model.hourlyTimeZoneText)
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .help(self.group.timeZone.identifier)
                    .accessibilityLabel("\(L("Statistics time zone")): \(model.hourlyTimeZoneText)")
                    .accessibilityIdentifier("spend-trend-time-zone")
            }
            if model.segments.isEmpty {
                ContentUnavailableView(
                    model.emptyStateTitle(group: self.group, sourceID: self.sourceID),
                    systemImage: "chart.bar.xaxis")
                    .frame(maxWidth: .infinity, minHeight: 210)
            } else {
                self.summary(model)
                if model.needsScrolling {
                    self.chart(model)
                        .chartScrollableAxes(.horizontal)
                        .chartXVisibleDomain(length: model.visibleDuration)
                        .chartScrollPosition(initialX: model.domain.upperBound
                            .addingTimeInterval(-model.visibleDuration))
                } else {
                    self.chart(model)
                }
                self.inspection(model)
            }
        }
    }

    private func summary(_ model: SpendTrendChartModel) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                self.totalSummary(model)
                Spacer()
                self.peakSummary(model)
            }
            VStack(alignment: .leading, spacing: 5) {
                self.totalSummary(model)
                self.peakSummary(model)
            }
        }
        .font(.caption)
    }

    private func totalSummary(_ model: SpendTrendChartModel) -> some View {
        HStack(spacing: 8) {
            Text(L(model.recordedSpendLabel)).foregroundStyle(.secondary)
            Text(self.costText(model.total)).font(.headline).monospacedDigit()
        }
    }

    @ViewBuilder
    private func peakSummary(_ model: SpendTrendChartModel) -> some View {
        if let peak = model.peak {
            HStack(spacing: 8) {
                Text(L("Highest recorded spend")).foregroundStyle(.secondary)
                Text("\(self.bucketText(peak.date, model: model)) · \(self.costText(peak.total))").monospacedDigit()
            }
        }
    }

    private func chart(_ model: SpendTrendChartModel) -> some View {
        let topIDs = spendTopOfStackIDs(for: model.segments, key: \.date, id: \.id, stackEnd: \.end)
        return Chart {
            ForEach(model.segments) { point in
                BarMark(
                    x: .value(
                        self.groupingText(model),
                        point.date,
                        unit: model.unit,
                        calendar: self.group.calendar),
                    yStart: .value(L("Estimated spend"), point.start),
                    yEnd: .value(L("Estimated spend"), point.end),
                    width: .ratio(0.72))
                    .foregroundStyle(Color(nsColor: SpendChartPalette.color(
                        sourceID: point.sourceID, provider: point.provider, providers: self.group.providers)))
                    .cornerRadius(0)
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: topIDs.contains(point.id) ? 3 : 0,
                        topTrailingRadius: topIDs.contains(point.id) ? 3 : 0))
                    .accessibilityLabel("\(self.sourceText(point)), \(self.bucketText(point.date, model: model))")
                    .accessibilityValue(self.costText(point.cost, sourceID: point.sourceID))
            }
            if let date = (self.inspectedDate ?? self.pinnedDate).flatMap({ model.inspectionDate(at: $0) }) {
                RuleMark(x: .value(self.groupingText(model), self.center(of: date, unit: model.unit)))
                    .foregroundStyle(.secondary.opacity(0.45))
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: model.domain, range: .plotDimension(startPadding: 18, endPadding: 18))
        .chartYScale(domain: model.yDomain)
        .chartXAxis {
            if self.section == .hourly {
                AxisMarks(preset: .aligned, values: model.hourlyTicks) { value in
                    AxisTick()
                    AxisValueLabel(
                        centered: false,
                        anchor: value.as(Date.self) == model.domain.upperBound ? .topTrailing
                            : value.as(Date.self) == model.domain.lowerBound ? .topLeading : .top)
                    {
                        if let date = value.as(Date.self) {
                            Text(model.hourlyAxisText(date))
                                .monospacedDigit()
                                .font(.callout).foregroundStyle(Color.primary.opacity(0.85)).fixedSize()
                        }
                    }
                }
            } else {
                AxisMarks(values: .stride(by: model.unit, count: self.tickStride(model))) { value in
                    AxisTick()
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(self.axisText(date, unit: model.unit))
                                .font(.callout).foregroundStyle(Color.primary.opacity(0.85)).fixedSize()
                        }
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(UsageFormatter.compactCurrencyString(amount, currencyCode: self.group.currencyCode))
                            .font(.callout).foregroundStyle(Color.primary.opacity(0.85))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            self.inspectedDate = self.date(
                                at: location,
                                proxy: proxy,
                                geometry: geometry,
                                model: model)
                        case .ended: self.inspectedDate = nil
                        }
                    }
                    .onTapGesture { location in
                        guard let date = self.date(at: location, proxy: proxy, geometry: geometry, model: model)
                        else { return }
                        self.pinnedDate = date
                        self.inspectedDate = nil
                        guard self.section == .daily else { return }
                        if model.unit != .day, let interval = model.interval(at: date) {
                            self.onSelectInterval?(interval)
                        } else if self.group.hourlyPoints.contains(where: {
                            self.group.calendar.isDate($0.hour, inSameDayAs: date)
                        }) {
                            self.onSelectDay?(date)
                        }
                    }
            }
        }
        .frame(height: 210)
        .environment(\.calendar, self.group.calendar)
        .environment(\.timeZone, self.group.timeZone)
        .accessibilityLabel(self.section.title)
        .accessibilityValue(self.section == .hourly
            ? spendDashboardHourlyChartAccessibilityValue(
                hourCount: model.buckets.count,
                serviceCount: Set(model.segments.map(\.sourceID)).count)
            : "\(self.groupingText(model)) · \(self.dateText(model.scope.lowerBound)) – "
            + self.dateText(model.scope.upperBound.addingTimeInterval(-1)))
        .accessibilityIdentifier("spend-trend-chart")
    }

    private func inspection(_ model: SpendTrendChartModel) -> some View {
        let date = (self.inspectedDate ?? self.pinnedDate).flatMap { model.inspectionDate(at: $0) }
        let bucket = date.flatMap { model.bucket(at: $0) } ?? (date == nil ? model.peak : nil)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Picker(self.groupingText(model), selection: Binding<Date?>(
                    get: { bucket?.date },
                    set: { self.pinnedDate = $0 }))
                {
                    if bucket == nil {
                        Text(self.bucketText(date ?? model.domain.lowerBound, model: model)).tag(nil as Date?)
                    }
                    ForEach(model.buckets) { item in
                        Text(self.bucketText(item.date, model: model)).tag(Optional(item.date))
                    }
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small)
                .frame(maxWidth: 240, alignment: .leading)
                .accessibilityIdentifier("spend-trend-inspection-picker")
                if let bucket, self.section == .daily,
                   model.unit != .day || self.group.hourlyPoints.contains(where: {
                       self.group.calendar.isDate($0.hour, inSameDayAs: bucket.date)
                   })
                {
                    Button(model.unit == .day ? L("Hour") : L("Show details")) {
                        if model.unit == .day {
                            self.onSelectDay?(bucket.date)
                        } else if let interval = model.interval(at: bucket.date) {
                            self.onSelectInterval?(interval)
                        }
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("spend-trend-inspection-details")
                }
                Spacer()
                Text(bucket.map { self.costText($0.total) } ?? L("No data available"))
                    .fontWeight(.semibold).monospacedDigit()
            }
            MenuBarLayoutChipFlowLayout(spacing: 12) { self.inspectionRows(bucket) }
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("spend-trend-inspection")
    }

    private func inspectionRows(_ bucket: SpendTrendChartModel.Bucket?) -> some View {
        ForEach(bucket?.segments ?? []) { segment in
            HStack(spacing: 5) {
                Circle().fill(Color(nsColor: SpendChartPalette.color(
                    sourceID: segment.sourceID, provider: segment.provider, providers: self.group.providers)))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                SpendProviderIcon(
                    provider: segment.provider,
                    sourceKind: self.group.providers.first { $0.id == segment.sourceID }?.sourceKind ?? .native,
                    style: .brand)
                Text(self.sourceText(segment))
                Text(self.costText(segment.cost, sourceID: segment.sourceID)).monospacedDigit()
            }
        }
    }

    private func date(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy,
        model: SpendTrendChartModel) -> Date?
    {
        guard let frame = proxy.plotFrame, geometry[frame].contains(location),
              let date = proxy.value(atX: location.x - geometry[frame].minX, as: Date.self)
        else { return nil }
        return model.inspectionDate(at: date)
    }

    private func center(of date: Date, unit: Calendar.Component) -> Date {
        guard let interval = self.group.calendar.dateInterval(of: unit, for: date)
        else { return date }
        return interval.start.addingTimeInterval(interval.duration / 2)
    }

    private func tickStride(_ model: SpendTrendChartModel) -> Int {
        let days = Double(model.visibleDayCount)
        if model.unit == .month { return max(1, Int(ceil(days / 30 / 4))) }
        if model.unit == .weekOfYear { return max(1, Int(ceil(days / 7 / 4))) }
        return days > 14 ? 7 : days > 7 ? 3 : 1
    }

    private func axisText(_ date: Date, unit: Calendar.Component) -> String {
        let format = Date.FormatStyle(
            locale: codexBarLocalizedLocale(),
            calendar: self.group.calendar,
            timeZone: self.group.timeZone)
        if unit == .month { return date.formatted(format.year(.twoDigits).month(.abbreviated)) }
        return date.formatted(format.month().day())
    }

    private func groupingText(_ model: SpendTrendChartModel) -> String {
        switch model.unit {
        case .hour: L("Hour")
        case .month: L("Monthly")
        case .weekOfYear: L("Weekly")
        default: L("Day")
        }
    }

    private func bucketText(_ date: Date, model: SpendTrendChartModel) -> String {
        guard model.unit == .weekOfYear || model.unit == .month,
              let interval = model.interval(at: date) else { return self.dateText(date) }
        return "\(self.dateText(interval.start)) – \(self.dateText(interval.end.addingTimeInterval(-1)))"
    }

    private func dateText(_ date: Date) -> String {
        let format = Date.FormatStyle(
            locale: codexBarLocalizedLocale(),
            calendar: self.group.calendar,
            timeZone: self.group.timeZone).year().month(.abbreviated).day()
        let text = date.formatted(format)
        return self.section == .hourly
            ? "\(text) · \(SpendTrendChartModel.hourText(date, calendar: self.group.calendar))" : text
    }

    private func sourceText(_ segment: SpendTrendChartModel.Segment) -> String {
        self.group.providers.first(where: { $0.id == segment.sourceID })
            .map { SpendChartPalette.label($0, providers: self.group.providers) } ?? segment.name
    }

    func costText(_ cost: Double?, sourceID: String? = nil) -> String {
        let source = (sourceID ?? self.sourceID).flatMap { id in self.group.providers.first { $0.id == id } }
        return spendDashboardMetricText(
            cost: cost,
            tokens: nil,
            currencyCode: self.group.currencyCode,
            costIsLowerBound: source.map { $0.costIsLowerBound || $0.incompleteRequestCount > 0 }
                ?? self.group.hasPartialCost)
    }
}
