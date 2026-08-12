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

func spendDashboardRangeText(_ range: SpendDashboardRange) -> String {
    range.dayCount.map(spendDashboardDayRangeText) ?? L("All Time")
}

func spendDashboardAvailableHistoryText(
    since date: Date,
    coveredDayCount: Int,
    calendar: Calendar = .current) -> String
{
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = codexBarLocalizedLocale()
    formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
    return "\(L("Available history since %@", formatter.string(from: date))) · "
        + L("%d covered days", coveredDayCount)
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

func codexCostCatchUpProgressText(_ activity: CodexCostCatchUpActivity) -> String {
    if activity.totalBytes > 0 {
        let processed = ByteCountFormatter.string(
            fromByteCount: activity.processedBytes,
            countStyle: .file)
        let total = ByteCountFormatter.string(
            fromByteCount: activity.totalBytes,
            countStyle: .file)
        return "\(processed) / \(total)"
    }
    if activity.totalFiles > 0 {
        return "\(codexBarLocalizedInteger(activity.completedFiles)) / "
            + codexBarLocalizedInteger(activity.totalFiles)
    }
    return L("Loading…")
}

struct SpendDashboardHeader: View {
    let selectedRange: SpendDashboardRange
    let isRefreshing: Bool
    let isCostTrackingEnabled: Bool
    let selectRange: (SpendDashboardRange) -> Void
    let refresh: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Usage & Spend"))
                    .font(.title2.weight(.semibold))
                Text(L("Local estimated cost history across supported providers."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 2) {
                ForEach(SpendDashboardRange.allCases, id: \.self) { range in
                    Button {
                        self.selectRange(range)
                    } label: {
                        Text(spendDashboardRangeText(range))
                            .font(.callout.weight(range == self.selectedRange ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(
                                range == self.selectedRange ? Color.accentColor : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .foregroundStyle(range == self.selectedRange ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(spendDashboardRangeText(range))
                    .accessibilityAddTraits(range == self.selectedRange ? .isSelected : [])
                }
            }
            .padding(2)
            .background(Color.secondary.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(width: 210)

            Button(action: self.refresh) {
                if self.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Label(L("Refresh"), systemImage: "arrow.clockwise")
                }
            }
            .disabled(self.isRefreshing || !self.isCostTrackingEnabled)
        }
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
    @State private var isVisible = false

    init(settings: SettingsStore, store: UsageStore) {
        self.settings = settings
        self.store = store
        self._controller = State(initialValue: SpendDashboardController(requestBuilder: { mode in
            await SpendDashboardSource.makeRequest(settings: settings, store: store, mode: mode)
        }, cachedLoader: { request in
            await SpendDashboardSource.loadCached(request)
        }, historyLedger: SpendHistoryLedger()))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                self.header
                self.codexCostCatchUpPanel
                self.content
                self.provenance
                self.shareAction
            }
            .padding(24)
        }
        .background(FocusResigningBackground())
        .onAppear {
            self.isVisible = true
            self.controller.refreshDateWindow()
            self.controller.update(configuration: self.configuration)
            if !self.controller.isRefreshing {
                self.synchronizeCodexCostCatchUp()
            }
        }
        .onChange(of: self.configuration) { _, configuration in
            self.controller.update(configuration: configuration)
            if self.isVisible, !self.controller.isRefreshing {
                self.synchronizeCodexCostCatchUp()
            }
        }
        .onChange(of: self.controller.isRefreshing) { _, isRefreshing in
            if self.isVisible, !isRefreshing {
                self.synchronizeCodexCostCatchUp()
            }
        }
        .onDisappear {
            self.isVisible = false
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
        SpendDashboardHeader(
            selectedRange: self.controller.selectedRange,
            isRefreshing: self.controller.isRefreshing,
            isCostTrackingEnabled: self.settings.costUsageEnabled,
            selectRange: { self.controller.selectRange($0) },
            refresh: { self.controller.refresh() })
    }

    @ViewBuilder
    private var codexCostCatchUpPanel: some View {
        if let activity = self.store.spendDashboardCodexCostCatchUpActivity,
           activity.phase != .complete
        {
            SpendDashboardPanel {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Label(
                            self.codexCostCatchUpTitle(activity),
                            systemImage: activity.phase == .paused ? "pause.circle" : "externaldrive")
                            .font(.headline)
                        Spacer()
                        Text(codexCostCatchUpProgressText(activity))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if let progress = activity.fractionCompleted {
                        ProgressView(value: progress)
                    } else if activity.phase == .indexing {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if let staleSnapshotUpdatedAt = activity.staleSnapshotUpdatedAt {
                        HStack(spacing: 6) {
                            Label(L("stale data"), systemImage: "clock.badge.exclamationmark")
                            Text(L(
                                "Updated relative %@",
                                staleSnapshotUpdatedAt.relativeDescription()))
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                    }

                    Text(self.codexCostCatchUpDetail(activity))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        if activity.pauseReason == .user
                            || activity.pauseReason == .noProgress
                            || self.codexCostCatchUpHasError(activity)
                        {
                            Button(L("Refresh")) {
                                self.startCodexCostCatchUp(mode: .automatic)
                            }
                        } else if activity.mode == .automatic {
                            Button(L("Finish now")) {
                                self.startCodexCostCatchUp(mode: .accelerated)
                            }
                        } else {
                            Button(L("Continue in background")) {
                                self.startCodexCostCatchUp(mode: .automatic)
                            }
                        }

                        if activity.pauseReason != .user,
                           activity.pauseReason != .noProgress,
                           !self.codexCostCatchUpHasError(activity)
                        {
                            Button(L("Cancel")) {
                                self.store.stopSpendDashboardCodexCostCatchUp()
                            }
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func codexCostCatchUpHasError(_ activity: CodexCostCatchUpActivity) -> Bool {
        if case .error = activity.pauseReason {
            return true
        }
        return false
    }

    private func synchronizeCodexCostCatchUp() {
        self.store.synchronizeSpendDashboardCodexCostCatchUp(
            accounts: self.codexSpendScanRequests)
    }

    private func startCodexCostCatchUp(mode: CodexCostCatchUpMode) {
        self.store.startSpendDashboardCodexCostCatchUpIfNeeded(
            accounts: self.codexSpendScanRequests,
            mode: mode)
    }

    private var codexSpendScanRequests: [CodexSpendScanRequest] {
        guard self.configuration.costUsageEnabled,
              self.configuration.providerIDs.contains(UsageProvider.codex.rawValue)
        else { return [] }
        return SpendDashboardSource.codexRequests(settings: self.settings, store: self.store)
    }

    private func codexCostCatchUpTitle(_ activity: CodexCostCatchUpActivity) -> String {
        let prefix = L("Local estimated history")
        switch activity.phase {
        case .indexing:
            return "\(prefix) · \(L("Refreshing"))"
        case .paused:
            return "\(prefix) · \(L("Inactive"))"
        case .complete:
            return "\(prefix) · \(L("Done"))"
        }
    }

    private func codexCostCatchUpDetail(_ activity: CodexCostCatchUpActivity) -> String {
        switch activity.pauseReason {
        case .lowPower:
            L("Battery Saver")
        case .thermal, .user:
            L("Inactive")
        case .noProgress:
            L("Error")
        case let .error(message):
            L("cost_status_error", L("Cost"), message)
        case nil:
            L("Estimated from local Codex logs for the selected account.")
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
            let emptyState = SpendDashboardEmptyState.make(isRefreshing: self.controller.isRefreshing)
            SpendDashboardPanel {
                ContentUnavailableView {
                    Label(emptyState.title, systemImage: "chart.bar.xaxis")
                } description: {
                    Text(emptyState.message)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            }
        } else {
            ForEach(self.controller.model.groups) { group in
                SpendCurrencySection(
                    group: group,
                    range: self.controller.model.range,
                    requestedDays: self.controller.model.requestedDays)
            }
        }

        if self.settings.costUsageEnabled, !self.controller.model.tokenActivity.isEmpty {
            SpendDashboardPanel {
                SpendActivityHeatmapView(points: self.controller.model.tokenActivity)
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
                    [self.store.snapshot(for: row.provider.instanceID)]
                }
                if let name = ShareStatsSubscriptionName.first(from: snapshots, provider: row.provider) {
                    names[row.id] = name
                }
            }
        }
        return names
    }

    private var rangeBinding: Binding<SpendDashboardRange> {
        Binding(
            get: { self.controller.selectedRange },
            set: { self.controller.selectRange($0) })
    }
}

struct SpendDashboardEmptyState: Equatable {
    let title: String
    let message: String

    static func make(isRefreshing: Bool) -> Self {
        if isRefreshing {
            return Self(
                title: L("Refreshing"),
                message: L("Local estimated cost history across supported providers."))
        }
        return Self(
            title: L("No local cost history yet"),
            message: L("Turn on cost tracking or refresh after using a supported provider."))
    }
}

struct SpendCurrencySection: View {
    let group: SpendDashboardModel.CurrencyGroup
    let range: SpendDashboardRange
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

            Text(self.coverageText)
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

    private var coverageText: String {
        if self.range == .allTime {
            return spendDashboardAvailableHistoryText(
                since: self.group.providers.compactMap(\.coverageStart).min()
                    ?? self.group.chartDomain.lowerBound,
                coveredDayCount: self.group.coveredDayCount)
        }
        return "\(L("Local estimated history")) · " + spendDashboardCoverageText(
            covered: self.group.coveredDayCount,
            requested: self.requestedDays)
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
