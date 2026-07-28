import AppKit
import Charts
import CodexBarCore
import SwiftUI

func spendDashboardDayRangeText(_ days: Int) -> String {
    let template: String
    switch days {
    case 7: template = L("7d")
    case 30: template = L("30d")
    default: return codexBarLocalizedInteger(days)
    }
    return template.replacingOccurrences(
        of: String(days),
        with: codexBarLocalizedInteger(days))
}

func spendDashboardRankText(_ rank: Int) -> String {
    "#\(codexBarLocalizedInteger(rank))"
}

func spendDashboardRefreshFailureText(_ count: Int) -> String {
    "\(L("Refresh failures")): \(codexBarLocalizedInteger(count))"
}

func spendDashboardCoverageText(covered: Int, requested: Int) -> String {
    "\(L("Coverage")): \(codexBarLocalizedInteger(covered)) / \(codexBarLocalizedInteger(requested))"
}

func spendDashboardSelectedDailySummary(
    selectedDay: Date?,
    summaries: [SpendDashboardModel.DailySummary],
    calendar: Calendar = .current) -> SpendDashboardModel.DailySummary?
{
    guard let selectedDay else { return summaries.last }
    if let exact = summaries.first(where: { calendar.isDate($0.day, inSameDayAs: selectedDay) }) {
        return exact
    }
    return summaries.min {
        abs($0.day.timeIntervalSince(selectedDay)) < abs($1.day.timeIntervalSince(selectedDay))
    }
}

enum SpendDashboardModelHistoryPresentation: Equatable {
    case unavailable
    case empty
    case partial
    case complete
}

func spendDashboardModelHistoryPresentation(
    _ group: SpendDashboardModel.CurrencyGroup) -> SpendDashboardModelHistoryPresentation
{
    if group.models.isEmpty {
        return group.modelHistoryCompleteness == .incomplete ? .unavailable : .empty
    }
    return group.modelHistoryCompleteness == .incomplete ? .partial : .complete
}

@MainActor
struct SpendDashboardPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    @State private var controller: SpendDashboardController
    @State private var displayGBP: Bool
    @State private var usdToGBPRate: Double

    init(settings: SettingsStore, store: UsageStore) {
        self.settings = settings
        self.store = store
        let storedDisplayGBP = settings.userDefaults.object(
            forKey: SpendDisplayCurrencyPreference.displayGBPDefaultsKey) as? Bool
        self._displayGBP = State(initialValue: spendDashboardDefaultsToGBP(
            storedPreference: storedDisplayGBP))
        let storedRate = settings.userDefaults.object(
            forKey: SpendDisplayCurrencyPreference.usdToGBPRateDefaultsKey) as? Double
        self._usdToGBPRate = State(initialValue: spendDashboardUSDToGBPRate(
            storedRate ?? spendDashboardDefaultUSDToGBPRate))
        self._controller = State(initialValue: SpendDashboardController(requestBuilder: { mode in
            await SpendDashboardSource.makeRequest(settings: settings, store: store, mode: mode)
        }))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                self.header
                self.content
                self.provenance
                self.shareAction
            }
            .padding(24)
        }
        .background(FocusResigningBackground())
        .onAppear {
            self.controller.refreshDateWindow()
            self.controller.update(configuration: self.configuration)
        }
        .onChange(of: self.configuration) { _, configuration in
            self.controller.update(configuration: configuration)
        }
        .onChange(of: self.displayGBP) { _, displayGBP in
            self.settings.userDefaults.set(
                displayGBP,
                forKey: SpendDisplayCurrencyPreference.displayGBPDefaultsKey)
            self.store.persistWidgetSnapshot(reason: "currency-display")
        }
        .onChange(of: self.usdToGBPRate) { _, rate in
            self.settings.userDefaults.set(
                spendDashboardUSDToGBPRate(rate),
                forKey: SpendDisplayCurrencyPreference.usdToGBPRateDefaultsKey)
            self.store.persistWidgetSnapshot(reason: "currency-rate")
        }
        .onDisappear {
            self.controller.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            self.controller.refreshDateWindow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            self.controller.refreshDateWindow()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            self.controller.refreshDateWindow()
        }
    }

    private var configuration: SpendDashboardConfiguration {
        SpendDashboardSource.configuration(settings: self.settings, store: self.store)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Usage & Spend"))
                    .font(.title2.weight(.semibold))
                Text(L("Local estimated cost history across supported providers."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker(L("Time range"), selection: self.daysBinding) {
                Text(spendDashboardDayRangeText(7)).tag(7)
                Text(spendDashboardDayRangeText(30)).tag(30)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 116)

            Button {
                self.controller.refresh()
            } label: {
                if self.controller.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Label(L("Refresh"), systemImage: "arrow.clockwise")
                }
            }
            .disabled(self.controller.isRefreshing || !self.settings.costUsageEnabled)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !self.settings.costUsageEnabled {
            SpendDashboardPanel {
                ContentUnavailableView {
                    Label(L("Cost tracking is off"), systemImage: "chart.bar.xaxis")
                } description: {
                    Text(L("Turn on Track costs to build local estimates."))
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            }
        } else if self.controller.model.groups.isEmpty {
            SpendDashboardPanel {
                ContentUnavailableView {
                    Label(L("No local cost history yet"), systemImage: "chart.bar.xaxis")
                } description: {
                    Text(L("Turn on cost tracking or refresh after using a supported provider."))
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            }
        } else {
            ForEach(self.controller.model.groups) { group in
                SpendCurrencySection(
                    group: group,
                    requestedDays: self.controller.model.requestedDays,
                    displayGBP: self.$displayGBP,
                    usdToGBPRate: self.$usdToGBPRate)
            }
        }

        if self.controller.failedSourceCount > 0 {
            Label(
                spendDashboardRefreshFailureText(self.controller.failedSourceCount),
                systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var provenance: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.secondary)
            Text(L("Native currencies stay separate; Codex account rows exclude Pi session history."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Toggle(L("Track costs"), isOn: self.$settings.costUsageEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var shareAction: some View {
        HStack {
            Spacer()
            Button {
                guard let payload = self.sharePayload else { return }
                ShareStatsPresenter.shared.present(payload: payload)
            } label: {
                Label(L("Share Stats…"), systemImage: "square.and.arrow.up")
            }
            .disabled(self.sharePayload == nil)
        }
    }

    private var sharePayload: ShareStatsPayload? {
        ShareStatsBuilder.make(
            model: self.controller.model,
            subscriptionNames: self.subscriptionNames)
    }

    private var subscriptionNames: [String: ShareStatsSubscriptionName] {
        var names: [String: ShareStatsSubscriptionName] = [:]
        let codexRowCount = self.controller.model.groups
            .flatMap(\.providers)
            .count { $0.provider == .codex }
        for group in self.controller.model.groups {
            for row in group.providers {
                let snapshots: [UsageSnapshot?] = if row.provider == .codex,
                                                     row.id.hasPrefix("codex:")
                {
                    [
                        self.store.codexAccountSnapshots.first {
                            row.id == "codex:\($0.id)"
                        }?.snapshot,
                        codexRowCount == 1 ? self.store.snapshot(for: .codex) : nil,
                    ]
                } else {
                    [self.store.snapshot(for: row.provider)]
                }
                if let name = ShareStatsSubscriptionName.first(from: snapshots, provider: row.provider) {
                    names[row.id] = name
                }
            }
        }
        return names
    }

    private var daysBinding: Binding<Int> {
        Binding(
            get: { self.controller.selectedDays },
            set: { self.controller.selectDays($0) })
    }
}

private struct SpendCurrencySection: View {
    let group: SpendDashboardModel.CurrencyGroup
    let requestedDays: Int
    @Binding var displayGBP: Bool
    @Binding var usdToGBPRate: Double
    @State private var selectedDay: Date?

    var body: some View {
        let displayGroup = self.displayGroup
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                if self.group.currencyCode == "USD" {
                    Picker(self.group.currencyCode, selection: self.$displayGBP) {
                        Text(verbatim: "USD").tag(false)
                        Text(verbatim: "GBP").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 112)
                    if self.displayGBP {
                        HStack(spacing: 5) {
                            Text(verbatim: "$1 = £")
                                .foregroundStyle(.secondary)
                            TextField(
                                "",
                                value: self.$usdToGBPRate,
                                format: .number.precision(.fractionLength(2...4)))
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 64)
                                .accessibilityLabel(Text(verbatim: "USD → GBP"))
                        }
                        .font(.caption)
                    }
                } else {
                    Text(displayGroup.currencyCode)
                        .font(.headline)
                }
                Spacer()
                Text(displayGroup.totalCost.map {
                    UsageFormatter.currencyString($0, currencyCode: displayGroup.currencyCode)
                } ?? L("Spend unavailable"))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }

            Text(
                "\(L("Local estimated history")) · " +
                    spendDashboardCoverageText(
                        covered: displayGroup.coveredDayCount,
                        requested: self.requestedDays))
                .font(.caption)
                .foregroundStyle(.secondary)

            SpendDashboardPanel {
                HStack(spacing: 24) {
                    SpendSummaryValue(
                        title: L("Estimated spend"),
                        value: displayGroup.totalCost.map {
                            UsageFormatter.currencyString($0, currencyCode: displayGroup.currencyCode)
                        } ?? "—")
                    SpendSummaryValue(
                        title: L("Tracked tokens"),
                        value: displayGroup.totalTokens.map(UsageFormatter.tokenCountString) ?? "—")
                    SpendSummaryValue(
                        title: L("Subscriptions"),
                        value: codexBarLocalizedInteger(displayGroup.providers.count))
                    Spacer()
                }
            }

            SpendDailyChart(
                group: displayGroup,
                selectedDay: self.$selectedDay)
            if let selectedSummary = self.selectedSummary {
                SpendSelectedDayPanel(
                    summary: selectedSummary,
                    currencyCode: displayGroup.currencyCode)
            }
            SpendDailyLedger(
                group: displayGroup,
                selectedDay: self.$selectedDay)
            SpendProviderPanel(group: displayGroup)
            SpendModelPanel(group: displayGroup)
        }
        .onAppear {
            self.normalizeSelection()
        }
        .onChange(of: self.group.dailySummaries) { _, _ in
            self.normalizeSelection()
        }
    }

    private var selectedSummary: SpendDashboardModel.DailySummary? {
        spendDashboardSelectedDailySummary(
            selectedDay: self.selectedDay,
            summaries: self.displayGroup.dailySummaries)
    }

    private var displayGroup: SpendDashboardModel.CurrencyGroup {
        guard self.displayGBP, self.group.currencyCode == "USD" else { return self.group }
        return self.group.converted(
            to: "GBP",
            rate: spendDashboardUSDToGBPRate(self.usdToGBPRate))
    }

    private func normalizeSelection() {
        self.selectedDay = self.selectedSummary?.day
    }
}

private struct SpendSummaryValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(self.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(self.value)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
        }
    }
}

private struct SpendSelectedDayPanel: View {
    let summary: SpendDashboardModel.DailySummary
    let currencyCode: String

    var body: some View {
        SpendDashboardPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Day"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(self.summary.day, format: .dateTime.weekday(.wide).day().month(.wide).year())
                            .font(.headline)
                    }
                    Spacer()
                    Text(UsageFormatter.currencyString(
                        self.summary.totalCost,
                        currencyCode: self.currencyCode))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                }

                HStack(spacing: 24) {
                    SpendSummaryValue(
                        title: L("Tracked tokens"),
                        value: self.summary.totalTokens.map(UsageFormatter.tokenCountString) ?? "—")
                    SpendSummaryValue(
                        title: L("Requests"),
                        value: self.summary.requestCount.map(codexBarLocalizedInteger) ?? "—")
                    SpendSummaryValue(
                        title: L("Providers"),
                        value: codexBarLocalizedInteger(self.activeProviders.count))
                    Spacer()
                }

                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(self.summary.providers) { row in
                        if row.id != self.summary.providers.first?.id {
                            Divider()
                        }
                        HStack(spacing: 10) {
                            SpendProviderIcon(provider: row.provider)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.displayName)
                                Text(self.usageLine(row))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(UsageFormatter.currencyString(
                                row.totalCost,
                                currencyCode: self.currencyCode))
                                .monospacedDigit()
                        }
                        .padding(.vertical, 7)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var activeProviders: [SpendDashboardModel.DailyProviderRow] {
        self.summary.providers.filter {
            $0.totalCost > 0 || ($0.totalTokens ?? 0) > 0 || ($0.requestCount ?? 0) > 0
        }
    }

    private func usageLine(_ row: SpendDashboardModel.DailyProviderRow) -> String {
        let tokens = row.totalTokens.map(UsageFormatter.tokenCountString) ?? "—"
        let requests = row.requestCount.map(codexBarLocalizedInteger) ?? "—"
        return "\(tokens) \(L("tokens")) · \(requests) \(L("requests"))"
    }
}

private struct SpendDailyLedger: View {
    let group: SpendDashboardModel.CurrencyGroup
    @Binding var selectedDay: Date?

    var body: some View {
        SpendDashboardPanel {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(L("Daily estimated spend")).font(.headline)
                    Spacer()
                }
                .padding(.bottom, 10)

                if self.group.dailySummaries.isEmpty {
                    ContentUnavailableView(
                        L("Spend unavailable"),
                        systemImage: "calendar.badge.exclamationmark")
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    self.header
                    Divider()
                    LazyVStack(spacing: 0) {
                        ForEach(Array(self.group.dailySummaries.reversed())) { summary in
                            Button {
                                self.selectedDay = summary.day
                            } label: {
                                self.row(summary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(self.accessibilityLabel(summary))
                            if summary.id != self.group.dailySummaries.first?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(L("Day")).frame(width: 132, alignment: .leading)
            Text(L("Providers")).frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            Text(L("Tracked tokens")).frame(width: 90, alignment: .trailing)
            Text(L("Requests")).frame(width: 72, alignment: .trailing)
            Text(L("Estimated spend")).frame(width: 116, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func row(_ summary: SpendDashboardModel.DailySummary) -> some View {
        HStack(spacing: 12) {
            Text(summary.day, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                .frame(width: 132, alignment: .leading)
            self.providerMix(summary)
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            Text(summary.totalTokens.map(UsageFormatter.tokenCountString) ?? "—")
                .frame(width: 90, alignment: .trailing)
            Text(summary.requestCount.map(codexBarLocalizedInteger) ?? "—")
                .frame(width: 72, alignment: .trailing)
            Text(UsageFormatter.currencyString(
                summary.totalCost,
                currencyCode: self.group.currencyCode))
                .fontWeight(.medium)
                .frame(width: 116, alignment: .trailing)
        }
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .background(
            self.isSelected(summary) ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func providerMix(_ summary: SpendDashboardModel.DailySummary) -> some View {
        let active = summary.providers.filter {
            $0.totalCost > 0 || ($0.totalTokens ?? 0) > 0 || ($0.requestCount ?? 0) > 0
        }
        if active.isEmpty {
            Text(L("No usage yet"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 5) {
                ForEach(active.prefix(4)) { row in
                    SpendProviderIcon(provider: row.provider)
                        .help(row.displayName)
                }
                if active.count > 4 {
                    Text("+\(codexBarLocalizedInteger(active.count - 4))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func isSelected(_ summary: SpendDashboardModel.DailySummary) -> Bool {
        guard let selectedDay else { return false }
        return Calendar.current.isDate(summary.day, inSameDayAs: selectedDay)
    }

    private func accessibilityLabel(_ summary: SpendDashboardModel.DailySummary) -> String {
        let day = summary.day.formatted(
            .dateTime.weekday(.wide).day().month(.wide).year().locale(codexBarLocalizedLocale()))
        let spend = UsageFormatter.currencyString(summary.totalCost, currencyCode: self.group.currencyCode)
        return "\(day), \(spend)"
    }
}

private struct SpendProviderPanel: View {
    let group: SpendDashboardModel.CurrencyGroup

    var body: some View {
        SpendDashboardPanel {
            VStack(alignment: .leading, spacing: 0) {
                Text(L("By subscription")).font(.headline).padding(.bottom, 8)
                ForEach(self.group.providers) { row in
                    if row.rank > 1 {
                        Divider()
                    }
                    HStack(spacing: 10) {
                        Text(spendDashboardRankText(row.rank))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 26, alignment: .leading)
                        SpendProviderIcon(provider: row.provider)
                        Text(row.displayName).lineLimit(1)
                        Spacer()
                        Text(row.totalCost.map {
                            UsageFormatter.currencyString($0, currencyCode: self.group.currencyCode)
                        } ?? L("Spend unavailable"))
                            .foregroundStyle(row.totalCost == nil ? .secondary : .primary)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 9)
                }
            }
        }
    }
}

private struct SpendModelPanel: View {
    let group: SpendDashboardModel.CurrencyGroup

    var body: some View {
        SpendDashboardPanel {
            VStack(alignment: .leading, spacing: 0) {
                Text(L("Models")).font(.headline).padding(.bottom, 8)
                let presentation = spendDashboardModelHistoryPresentation(self.group)
                switch presentation {
                case .unavailable:
                    Text(L("Model breakdown unavailable"))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                case .empty:
                    Text(L("No model-level history"))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                case .partial, .complete:
                    if presentation == .partial {
                        Label(L("Model breakdown unavailable"), systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 6)
                    }
                    ForEach(self.group.models.prefix(8)) { row in
                        if row.rank > 1 {
                            Divider()
                        }
                        HStack(spacing: 10) {
                            if presentation == .complete {
                                Text(spendDashboardRankText(row.rank))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 26, alignment: .leading)
                            } else {
                                Image(systemName: "circle.dashed")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 26, alignment: .leading)
                            }
                            SpendProviderIcon(provider: row.provider)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.modelName).lineLimit(1)
                                Text(row.providerName).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(row.totalCost.map {
                                UsageFormatter.currencyString($0, currencyCode: self.group.currencyCode)
                            } ?? "—")
                                .monospacedDigit()
                        }
                        .padding(.vertical, 9)
                    }
                }
            }
        }
    }
}

struct SpendDailyChartPresentation: Equatable {
    enum Content: Equatable {
        case chart
        case unavailable
    }

    struct Series: Equatable {
        let name: String
        let provider: UsageProvider
    }

    let content: Content
    let series: [Series]
    let dayCount: Int

    init(dailyPoints: [SpendDashboardModel.DailyPoint], aggregateTotal: Double?) {
        self.content = dailyPoints.isEmpty && aggregateTotal == nil ? .unavailable : .chart
        self.dayCount = Set(dailyPoints.map(\.day)).count

        var seenNames: Set<String> = []
        self.series = dailyPoints.compactMap { point in
            guard seenNames.insert(point.providerName).inserted else { return nil }
            return Series(name: point.providerName, provider: point.provider)
        }
    }

    var accessibilityValue: String {
        L("%d days of usage data across %d services", self.dayCount, self.series.count)
    }
}

private struct SpendDailyChart: View {
    let group: SpendDashboardModel.CurrencyGroup
    @Binding var selectedDay: Date?

    var body: some View {
        let presentation = SpendDailyChartPresentation(
            dailyPoints: self.group.dailyPoints,
            aggregateTotal: self.group.totalCost)
        SpendDashboardPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("Daily estimated spend")).font(.headline)
                if presentation.content == .unavailable {
                    ContentUnavailableView(L("Spend unavailable"), systemImage: "chart.bar.xaxis")
                        .frame(maxWidth: .infinity, minHeight: 170)
                } else {
                    Chart {
                        ForEach(self.group.dailyPoints) { point in
                            BarMark(
                                x: .value(L("Day"), point.day, unit: .day),
                                yStart: .value(L("Estimated spend"), point.stackStart),
                                yEnd: .value(L("Estimated spend"), point.stackEnd),
                                width: .ratio(0.72))
                                .foregroundStyle(by: .value(L("Provider"), point.providerName))
                                .accessibilityLabel(Text(self.pointAccessibilityLabel(point)))
                                .accessibilityValue(Text(UsageFormatter.currencyString(
                                    point.cost,
                                    currencyCode: self.group.currencyCode)))
                        }
                        if let selectedSummary = self.selectedSummary {
                            RuleMark(x: .value(L("Selected day"), selectedSummary.day, unit: .day))
                                .foregroundStyle(.primary.opacity(0.45))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        }
                    }
                    .chartXScale(domain: self.group.chartDomain)
                    .chartForegroundStyleScale(
                        domain: presentation.series.map(\.name),
                        range: presentation.series.map { self.providerColor($0.provider) })
                    .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let amount = value.as(Double.self) {
                                    Text(UsageFormatter.compactCurrencyString(
                                        amount,
                                        currencyCode: self.group.currencyCode))
                                }
                            }
                        }
                    }
                    .frame(height: 170)
                    .accessibilityLabel(L("Daily estimated spend"))
                    .accessibilityValue(presentation.accessibilityValue)
                    .chartXSelection(value: self.chartSelection)
                }
            }
        }
    }

    private var selectedSummary: SpendDashboardModel.DailySummary? {
        spendDashboardSelectedDailySummary(
            selectedDay: self.selectedDay,
            summaries: self.group.dailySummaries)
    }

    private var chartSelection: Binding<Date?> {
        Binding(
            get: { self.selectedSummary?.day },
            set: { value in
                self.selectedDay = spendDashboardSelectedDailySummary(
                    selectedDay: value,
                    summaries: self.group.dailySummaries)?.day
            })
    }

    private func pointAccessibilityLabel(_ point: SpendDashboardModel.DailyPoint) -> String {
        let day = point.day.formatted(
            .dateTime.month(.abbreviated).day().locale(codexBarLocalizedLocale()))
        return "\(point.providerName), \(day)"
    }

    private func providerColor(_ provider: UsageProvider) -> Color {
        let color = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
        return Color(red: color.red, green: color.green, blue: color.blue)
    }
}

private struct SpendProviderIcon: View {
    let provider: UsageProvider

    var body: some View {
        Group {
            if let icon = ProviderBrandIcon.image(for: self.provider) {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "circle.dotted")
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

private struct SpendDashboardPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        self.content
            .padding(16)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35))
            }
    }
}
