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

@MainActor
struct SpendDashboardPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    @State private var controller: SpendDashboardController

    init(settings: SettingsStore, store: UsageStore) {
        self.settings = settings
        self.store = store
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
                SpendCurrencySection(group: group, requestedDays: self.controller.model.requestedDays)
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

    private var daysBinding: Binding<Int> {
        Binding(
            get: { self.controller.selectedDays },
            set: { self.controller.selectDays($0) })
    }
}

private struct SpendCurrencySection: View {
    let group: SpendDashboardModel.CurrencyGroup
    let requestedDays: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(self.group.currencyCode)
                    .font(.headline)
                Spacer()
                Text(self.group.totalCost.map {
                    UsageFormatter.currencyString($0, currencyCode: self.group.currencyCode)
                } ?? L("Spend unavailable"))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }

            Text(
                "\(L("Local estimated history")) · " +
                    spendDashboardCoverageText(
                        covered: self.group.coveredDayCount,
                        requested: self.requestedDays))
                .font(.caption)
                .foregroundStyle(.secondary)

            SpendDashboardPanel {
                HStack(spacing: 24) {
                    SpendSummaryValue(
                        title: L("Estimated spend"),
                        value: self.group.totalCost.map {
                            UsageFormatter.currencyString($0, currencyCode: self.group.currencyCode)
                        } ?? "—")
                    SpendSummaryValue(
                        title: L("Tracked tokens"),
                        value: self.group.totalTokens.map(UsageFormatter.tokenCountString) ?? "—")
                    SpendSummaryValue(
                        title: L("Subscriptions"),
                        value: codexBarLocalizedInteger(self.group.providers.count))
                    Spacer()
                }
            }

            SpendProviderPanel(group: self.group)
            SpendModelPanel(group: self.group)
            SpendDailyChart(group: self.group)
        }
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
                if self.group.modelHistoryCompleteness == .incomplete {
                    Text(L("Model breakdown unavailable"))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                } else if self.group.models.isEmpty {
                    Text(L("No model-level history"))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                } else {
                    ForEach(self.group.models.prefix(8)) { row in
                        if row.rank > 1 {
                            Divider()
                        }
                        HStack(spacing: 10) {
                            Text(spendDashboardRankText(row.rank))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 26, alignment: .leading)
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
                    Chart(self.group.dailyPoints) { point in
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
                }
            }
        }
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
