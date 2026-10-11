import AppKit
import CodexBarCore
import SwiftUI
import UniformTypeIdentifiers

func spendDashboardLedgerDateText(_ day: Date, timeZone: TimeZone, accessibility: Bool = false) -> String {
    var format = accessibility
        ? Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide).year()
        : Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
    format.locale = codexBarLocalizedLocale()
    format.timeZone = timeZone
    return day.formatted(format)
}

func spendDashboardDayRangeText(_ days: Int) -> String {
    if days >= SpendDashboardSource.scanDays {
        return L("All")
    }
    guard let template = [7: L("7d"), 30: L("30d"), 90: L("90d")][days] else {
        return codexBarLocalizedInteger(days)
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

func spendDashboardTokenMixValue(_ value: Int?) -> String {
    value.map(UsageFormatter.tokenCountString) ?? "—"
}

func spendDashboardMetricText(
    cost: Double?,
    tokens: Int?,
    currencyCode: String,
    incompleteRequestCount: Int = 0,
    costIsLowerBound: Bool = false,
    tokensAreLowerBound: Bool = false) -> String
{
    // A truncated scan or an unpriced request makes the subtotal a floor, not an exact value.
    // The row must say so with the same `≥` marker the header and menu card already use.
    let parts = [
        cost.map {
            spendDashboardLowerBoundText(
                UsageFormatter.currencyString($0, currencyCode: currencyCode), isLowerBound: costIsLowerBound)
        },
        tokens.map {
            spendDashboardLowerBoundText(
                L("%@ tokens", UsageFormatter.tokenCountString($0)), isLowerBound: tokensAreLowerBound)
        },
    ].compactMap(\.self)
    return (parts.isEmpty ? "—" : parts.joined(separator: " · "))
        + UsageFormatter.incompleteUsageSuffix(incompleteRequestCount)
}

func spendDashboardLowerBoundText(_ value: String, isLowerBound: Bool) -> String {
    isLowerBound ? "≥ \(value)" : value
}

func spendDashboardCoverageChipText(_ coverage: CostUsageCoverageCounts) -> String {
    "\(L("Priced")) \(codexBarLocalizedInteger(coverage.priced)) · "
        + "\(L("Unpriced")) \(codexBarLocalizedInteger(coverage.unpriced)) · "
        + "\(L("Unmetered")) \(codexBarLocalizedInteger(coverage.unmetered)) · "
        + "\(L("Estimated")) \(codexBarLocalizedInteger(coverage.estimated))"
}

func spendDashboardProvenanceText(_ provenance: CostProvenance) -> String {
    switch provenance {
    case .listPriceEstimate: L("List-price equivalent")
    case .vendorMetered: L("Plan metered")
    case .mixed: L("Metered and list-price")
    case .unknown: L("Spend unavailable")
    }
}

func spendDashboardHourlyChartAccessibilityValue(hourCount: Int, serviceCount: Int) -> String {
    switch (hourCount == 1, serviceCount == 1) {
    case (true, true):
        L("1 hour of usage data across 1 service")
    case (false, true):
        L("%d hours of usage data across 1 service", hourCount)
    case (true, false):
        L("1 hour of usage data across %d services", serviceCount)
    case (false, false):
        L("%d hours of usage data across %d services", hourCount, serviceCount)
    }
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

@MainActor
struct SpendDashboardPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    @State private var isVisible = false
    @State private var userSelectedBackground = false
    @State private var isDataControlsExpanded = true

    init(settings: SettingsStore, store: UsageStore) {
        self.settings = settings
        self.store = store
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                self.header
                SpendTimeZoneControls(settings: self.settings)
                self.refreshStatus
                self.codexCostCatchUpPanel
                self.content
                self.dataControls
            }
            .padding(24)
        }
        .background(FocusResigningBackground())
        .onAppear {
            self.isVisible = true
            self.controller.update(configuration: self.configuration)
            self.controller.refreshIfStale()
            if !self.controller.isRefreshing {
                self.synchronizeCodexCostCatchUp()
            }
        }
        .onChange(of: self.configuration) { _, configuration in
            self.controller.update(configuration: configuration)
        }
        .onChange(of: self.configuration.codexAccountIdentities) { _, _ in
            if self.isVisible, !self.controller.isRefreshing {
                self.synchronizeCodexCostCatchUp()
            }
        }
        .onChange(of: self.configuration.costUsageEnabled) { _, _ in
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
            self.synchronizeCodexCostCatchUp()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            self.controller.refreshDateWindow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            self.controller.refreshDateWindow()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            self.controller.refreshDateWindow()
            self.controller.refreshIfStale()
        }
    }

    private var configuration: SpendDashboardConfiguration {
        SpendDashboardSource.configuration(settings: self.settings, store: self.store)
    }

    private var controller: SpendDashboardController {
        self.store.sharedSpendDashboardController()
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Usage & Spend"))
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    Text(L("Local estimated cost history across supported providers."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                Button {
                    self.store.refreshSpendDashboard(accounts: self.codexSpendScanRequests)
                } label: {
                    if self.controller.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(L("Refresh"), systemImage: "arrow.clockwise")
                    }
                }
                .disabled(self.controller.isRefreshing || !self.settings.costUsageEnabled)
            }
            Picker(L("Time range"), selection: self.periodBinding) {
                Text(spendDashboardDayRangeText(7)).tag(CostReportingPeriod.rolling(days: 7))
                Text(spendDashboardDayRangeText(30)).tag(CostReportingPeriod.rolling(days: 30))
                Text(spendDashboardDayRangeText(90)).tag(CostReportingPeriod.rolling(days: 90))
                Text(L("Month to date")).tag(CostReportingPeriod.monthToDate)
                Text(L("All")).tag(CostReportingPeriod.allTime)
                if case let .rolling(days) = self.controller.selectedPeriod, ![7, 30, 90].contains(days) {
                    Text(spendDashboardDayRangeText(days)).tag(self.controller.selectedPeriod)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 480, alignment: .leading)
            .accessibilityIdentifier("spend-dashboard-range-picker")
        }
    }

    @ViewBuilder
    private var refreshStatus: some View {
        if self.controller.failedSourceCount > 0 {
            Label(
                spendDashboardRefreshFailureText(self.controller.failedSourceCount),
                systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
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
                                self.userSelectedBackground = true
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
        guard self.isVisible else {
            self.userSelectedBackground = false
            self.store.synchronizeSpendDashboardCodexCostCatchUp(
                accounts: self.codexSpendScanRequests,
                preferredMode: .automatic)
            return
        }
        let preferredMode: CodexCostCatchUpMode? = self.userSelectedBackground ? nil : .accelerated
        self.store.synchronizeSpendDashboardCodexCostCatchUp(
            accounts: self.codexSpendScanRequests,
            preferredMode: preferredMode)
    }

    private func startCodexCostCatchUp(mode: CodexCostCatchUpMode) {
        if mode == .accelerated {
            self.userSelectedBackground = false
        }
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
                SpendDashboardCurrencySection(
                    group: group,
                    requestedDays: self.controller.model.requestedDays,
                    hidePersonalInfo: self.settings.hidePersonalInfo,
                    onSelectDay: { self.controller.selectDay($0) },
                    onClearSelectedDay: {
                        self.controller.selectDay(nil)
                    })
            }
        }

        if self.settings.costUsageEnabled, !self.controller.model.tokenActivity.isEmpty {
            SpendDashboardPanel {
                SpendActivityHeatmapView(
                    points: self.controller.model.tokenActivity,
                    calendar: self.settings.costUsageBucketCalendar,
                    selectedDay: self.controller.selectedDay,
                    onSelectDay: { day in
                        self.controller.selectDay(day)
                    })
            }
        }
    }

    private var dataControls: some View {
        SpendDashboardPanel {
            DisclosureGroup(isExpanded: self.$isDataControlsExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    self.provenance
                    Divider()
                    self.shareAction
                }
                .padding(.top, 12)
            } label: {
                Label {
                    Text(L("List-price equivalent — not a billing receipt."))
                        .font(.subheadline.weight(.medium))
                } icon: {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("spend-dashboard-data-controls")
        }
    }

    private var provenance: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L("Track costs"), isOn: self.$settings.costUsageEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
            if self.settings.costUsageEnabled {
                Toggle(L("Include OpenCodex usage logs"), isOn: self.$settings.openCodexUsageLogsEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                if self.settings.openCodexUsageLogsEnabled {
                    Toggle(
                        L("Hide native Codex when OpenCodex is present"),
                        isOn: self.$settings.hideNativeCodexCostWhenOpenCodexPresent)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                if !self.controller.model.groups.isEmpty {
                    SpendDashboardSourceFilter(settings: self.settings, model: self.controller.model)
                }
            }
        }
    }

    private var shareAction: some View {
        HStack {
            Button {
                self.copyJSON()
            } label: {
                Label(L("Copy JSON"), systemImage: "doc.on.doc")
            }
            .disabled(self.controller.model.groups.isEmpty)
            Button {
                self.exportJSON()
            } label: {
                Label(L("Export JSON"), systemImage: "square.and.arrow.down")
            }
            .disabled(self.controller.model.groups.isEmpty)
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

    private func copyJSON() {
        _ = SpendDashboardJSONExporter.copyToPasteboard(
            model: self.controller.model,
            hiddenSourceIDs: self.settings.spendDashboardHiddenSourceIDs)
    }

    private func exportJSON() {
        _ = SpendDashboardJSONExporter.save(
            model: self.controller.model,
            hiddenSourceIDs: self.settings.spendDashboardHiddenSourceIDs)
    }

    private var sharePayload: ShareStatsPayload? {
        ShareStatsPayloadFactory.make(model: self.controller.model, store: self.store)
    }

    private var periodBinding: Binding<CostReportingPeriod> {
        Binding(
            get: { self.controller.selectedPeriod },
            set: { self.controller.selectPeriod($0) })
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

enum SpendDashboardDetailSection: Hashable, Identifiable {
    case providers
    case projects
    case chats
    case sessions

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .providers: L("Providers")
        case .projects: L("Projects")
        case .chats: L("Independent chats")
        case .sessions: L("Sessions")
        }
    }
}

func spendDashboardAvailableDetailSections(
    hasProjects: Bool,
    hasSessions: Bool,
    hasChats: Bool = false) -> [SpendDashboardDetailSection]
{
    var sections: [SpendDashboardDetailSection] = [.providers]
    if hasProjects {
        sections.append(.projects)
    }
    if hasChats {
        sections.append(.chats)
    }
    if hasSessions {
        sections.append(.sessions)
    }
    return sections
}

/// Filter for display without regrouping ledger paths or changing any amounts.
func spendDashboardProjectRows(
    _ rows: [SpendDashboardModel.ProjectRow],
    isProjectless: Bool) -> [SpendDashboardModel.ProjectRow]
{
    rows.filter { $0.isProjectless == isProjectless }.enumerated().map { index, row in
        var ranked = row
        ranked.rank = index + 1
        return ranked
    }
}

enum SpendDashboardTrendSection: Hashable, Identifiable {
    case daily
    case hourly

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .daily: L("Daily estimated spend")
        case .hourly: L("Hourly estimated spend")
        }
    }

    var pickerTitle: String {
        switch self {
        case .daily: L("Overview")
        case .hourly: L("Hour")
        }
    }
}

func spendDashboardHasTokenMix(_ group: SpendDashboardModel.CurrencyGroup) -> Bool {
    group.tokenMix.inputTokens != nil
        || group.tokenMix.outputTokens != nil
        || group.tokenMix.cacheReadTokens != nil
        || group.tokenMix.cacheCreationTokens != nil
        || group.tokenMix.reasoningTokens != nil
}

struct SpendDashboardCurrencySection: View {
    let group: SpendDashboardModel.CurrencyGroup
    let requestedDays: Int
    let hidePersonalInfo: Bool
    let onClearSelectedDay: (() -> Void)?
    let onSelectDay: ((Date) -> Void)?
    @State private var selectedDetailSection: SpendDashboardDetailSection
    @State private var selectedTrendSection: SpendDashboardTrendSection

    init(
        group: SpendDashboardModel.CurrencyGroup,
        requestedDays: Int,
        hidePersonalInfo: Bool = false,
        initialDetailSection: SpendDashboardDetailSection = .providers,
        initialTrendSection: SpendDashboardTrendSection? = nil,
        onSelectDay: ((Date) -> Void)? = nil,
        onClearSelectedDay: (() -> Void)? = nil)
    {
        self.group = group
        self.requestedDays = requestedDays
        self.hidePersonalInfo = hidePersonalInfo
        self.onClearSelectedDay = onClearSelectedDay
        self.onSelectDay = onSelectDay
        self._selectedDetailSection = State(initialValue: initialDetailSection)
        self._selectedTrendSection = State(
            initialValue: initialTrendSection
                ?? (group.selectedDay != nil && !group.hourlyPoints.isEmpty ? .hourly : .daily))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(self.group.currencyCode)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(spendDashboardHistoryCaption(self.group, requestedDays: self.requestedDays))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SpendDashboardSummary(
                group: self.group,
                onClearSelectedDay: self.onClearSelectedDay)
            SpendDashboardDetailPanel(
                group: self.group,
                hidePersonalInfo: self.hidePersonalInfo,
                selection: self.$selectedDetailSection)
            SpendDashboardTrendPanel(
                group: self.group,
                selection: self.$selectedTrendSection,
                onSelectDay: self.onSelectDay.map { onSelectDay in
                    { day in
                        self.selectedDetailSection = .providers
                        onSelectDay(day)
                    }
                },
                onClearSelectedDay: self.onClearSelectedDay)
            SpendDailyLedger(group: self.group)
        }
        .environment(\.timeZone, self.group.timeZone)
        .environment(\.calendar, self.group.calendar)
    }
}

private struct SpendDashboardDetailPanel: View {
    let group: SpendDashboardModel.CurrencyGroup
    let hidePersonalInfo: Bool
    @Binding var selection: SpendDashboardDetailSection

    var body: some View {
        SpendDashboardPanel {
            VStack(alignment: .leading, spacing: 10) {
                if self.availableSections.count > 1 {
                    Picker(L("Usage & Spend"), selection: self.normalizedSelection) {
                        ForEach(self.availableSections) { section in
                            Text(section.title).tag(section)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(maxWidth: 460, alignment: .leading)
                    .accessibilityIdentifier("spend-dashboard-detail-picker")
                }

                self.detailContent
            }
        }
    }

    private var availableSections: [SpendDashboardDetailSection] {
        spendDashboardAvailableDetailSections(
            hasProjects: self.group.projects.contains { !$0.isProjectless },
            hasSessions: !self.group.sessions.isEmpty,
            hasChats: self.group.projects.contains(where: \.isProjectless))
    }

    private var activeSection: SpendDashboardDetailSection {
        self.availableSections.contains(self.selection) ? self.selection : self.availableSections[0]
    }

    private var normalizedSelection: Binding<SpendDashboardDetailSection> {
        Binding(
            get: { self.activeSection },
            set: { self.selection = $0 })
    }

    @ViewBuilder
    private var detailContent: some View {
        switch self.activeSection {
        case .providers:
            SpendProviderBreakdownRows(group: self.group)
        case .projects:
            SpendProjectRows(group: self.group, hidePersonalInfo: self.hidePersonalInfo, isProjectless: false)
        case .chats:
            SpendProjectRows(group: self.group, hidePersonalInfo: self.hidePersonalInfo, isProjectless: true)
        case .sessions:
            SpendSessionRows(group: self.group, hidePersonalInfo: self.hidePersonalInfo)
        }
    }
}

private struct SpendProjectRows: View {
    let group: SpendDashboardModel.CurrencyGroup
    let hidePersonalInfo: Bool
    let isProjectless: Bool
    @State private var showsAllRows = false

    private static let collapsedRowCount = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(self.visibleRows) { row in
                let identity = row.displayIdentity(hidePersonalInfo: self.hidePersonalInfo)
                if row.rank > 1 {
                    Divider()
                }
                HStack(spacing: 10) {
                    Text(spendDashboardRankText(row.rank))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 26, alignment: .leading)
                    Image(systemName: row.isProjectless ? "bubble.left.and.bubble.right" : "folder")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(identity.name)
                            .lineLimit(1)
                            .help(identity.path ?? identity.name)
                        Text(row.providerName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let path = identity.path,
                           row.needsPathDisambiguation(in: self.rows)
                        {
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(path)
                        }
                    }
                    Spacer()
                    Text(spendDashboardMetricText(
                        cost: row.totalCost,
                        tokens: row.totalTokens,
                        currencyCode: self.group.currencyCode))
                        .monospacedDigit()
                }
                .padding(.vertical, 9)
            }
            SpendPanelExpandButton(
                rowCount: self.rows.count,
                collapsedRowCount: Self.collapsedRowCount,
                showsAllRows: self.$showsAllRows)
        }
    }

    private var visibleRows: ArraySlice<SpendDashboardModel.ProjectRow> {
        self.rows.prefix(self.showsAllRows ? self.rows.count : Self.collapsedRowCount)
    }

    private var rows: [SpendDashboardModel.ProjectRow] {
        spendDashboardProjectRows(self.group.projects, isProjectless: self.isProjectless)
    }
}

private struct SpendPanelExpandButton: View {
    let rowCount: Int
    let collapsedRowCount: Int
    @Binding var showsAllRows: Bool

    var body: some View {
        if self.rowCount > self.collapsedRowCount {
            Button {
                self.showsAllRows.toggle()
            } label: {
                Text(
                    self.showsAllRows
                        ? L("Show less")
                        : L("Show all (%d)", self.rowCount))
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .padding(.top, 6)
        }
    }
}

private enum SpendDailyLedgerLayout {
    static let dayWidth: CGFloat = 112
    static let providerMinimumWidth: CGFloat = 96
    static let trackedTokensWidth: CGFloat = 90
    static let requestsWidth: CGFloat = 72
    static let estimatedSpendWidth: CGFloat = 116
    static let columnSpacing: CGFloat = 12
    static let horizontalPadding: CGFloat = 8
    static let minimumTableWidth: CGFloat =
        dayWidth
            + providerMinimumWidth
            + trackedTokensWidth
            + requestsWidth
            + estimatedSpendWidth
            + (columnSpacing * 4)
            + (horizontalPadding * 2)
}

/// Bound initial ledger layout on long ranges; expansion still exposes the complete history.
func spendDailyLedgerVisibleSummaries(
    _ summaries: [SpendDashboardModel.DailySummary],
    showsAllRows: Bool,
    collapsedRowCount: Int) -> [SpendDashboardModel.DailySummary]
{
    Array(summaries.suffix(showsAllRows ? summaries.count : collapsedRowCount).reversed())
}

private struct SpendDailyLedger: View {
    let group: SpendDashboardModel.CurrencyGroup
    @State private var showsAllRows = false

    static let collapsedRowCount = 30

    private var visibleSummaries: [SpendDashboardModel.DailySummary] {
        spendDailyLedgerVisibleSummaries(
            self.group.dailySummaries,
            showsAllRows: self.showsAllRows,
            collapsedRowCount: Self.collapsedRowCount)
    }

    var body: some View {
        SpendDashboardPanel {
            VStack(alignment: .leading, spacing: 0) {
                Text(L("Daily estimated spend"))
                    .font(.headline)
                    .padding(.bottom, 10)

                if self.group.dailySummaries.isEmpty {
                    ContentUnavailableView(
                        L("Spend unavailable"),
                        systemImage: "calendar.badge.exclamationmark")
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 0) {
                            self.header
                            Divider()
                            VStack(spacing: 0) {
                                ForEach(Array(self.visibleSummaries.enumerated()), id: \.element.id) { index, summary in
                                    if index > 0 {
                                        Divider()
                                    }
                                    SpendDailyLedgerRow(
                                        summary: summary,
                                        currencyCode: self.group.currencyCode,
                                        timeZone: self.group.timeZone)
                                }
                            }
                        }
                        .frame(minWidth: SpendDailyLedgerLayout.minimumTableWidth, alignment: .leading)
                    }
                    SpendPanelExpandButton(
                        rowCount: self.group.dailySummaries.count,
                        collapsedRowCount: Self.collapsedRowCount,
                        showsAllRows: self.$showsAllRows)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: SpendDailyLedgerLayout.columnSpacing) {
            Text(L("Day")).frame(width: SpendDailyLedgerLayout.dayWidth, alignment: .leading)
            Text(L("Providers")).frame(
                minWidth: SpendDailyLedgerLayout.providerMinimumWidth,
                maxWidth: .infinity,
                alignment: .leading)
            Text(L("Tracked tokens")).frame(
                width: SpendDailyLedgerLayout.trackedTokensWidth,
                alignment: .trailing)
            Text(L("Requests")).frame(
                width: SpendDailyLedgerLayout.requestsWidth,
                alignment: .trailing)
            Text(L("Estimated spend")).frame(
                width: SpendDailyLedgerLayout.estimatedSpendWidth,
                alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, SpendDailyLedgerLayout.horizontalPadding)
        .padding(.vertical, 6)
    }
}

private struct SpendDailyLedgerRow: View {
    let summary: SpendDashboardModel.DailySummary
    let currencyCode: String
    let timeZone: TimeZone

    var body: some View {
        HStack(spacing: SpendDailyLedgerLayout.columnSpacing) {
            Text(spendDashboardLedgerDateText(self.summary.day, timeZone: self.timeZone))
                .frame(width: SpendDailyLedgerLayout.dayWidth, alignment: .leading)
            self.providerMix
                .frame(
                    minWidth: SpendDailyLedgerLayout.providerMinimumWidth,
                    maxWidth: .infinity,
                    alignment: .leading)
            Text(self.tokensText)
                .frame(width: SpendDailyLedgerLayout.trackedTokensWidth, alignment: .trailing)
            Text(self.requestsText)
                .frame(width: SpendDailyLedgerLayout.requestsWidth, alignment: .trailing)
            Text(spendDashboardLedgerCostText(self.summary, currencyCode: self.currencyCode))
                .fontWeight(.medium)
                .frame(width: SpendDailyLedgerLayout.estimatedSpendWidth, alignment: .trailing)
        }
        .monospacedDigit()
        .padding(.horizontal, SpendDailyLedgerLayout.horizontalPadding)
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.accessibilityLabel)
    }

    @ViewBuilder
    private var providerMix: some View {
        if self.activeProviders.isEmpty {
            Text(L("No usage yet"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 5) {
                ForEach(self.activeProviders.prefix(4)) { row in
                    SpendProviderIcon(provider: row.provider)
                }
                if self.activeProviders.count > 4 {
                    Text("+\(codexBarLocalizedInteger(self.activeProviders.count - 4))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .help(self.activeProviders.map(\.displayName).joined(separator: ", "))
        }
    }

    private var activeProviders: [SpendDashboardModel.DailyProviderRow] {
        self.summary.providers.filter { !$0.isKnownIdle }
    }

    private var tokensText: String {
        spendDashboardLedgerTokenText(self.summary)
    }

    private var requestsText: String {
        spendDashboardLedgerRequestText(self.summary)
    }

    private var accessibilityLabel: String {
        let day = spendDashboardLedgerDateText(self.summary.day, timeZone: self.timeZone, accessibility: true)
        let providers = self.activeProviders.isEmpty
            ? L("No usage yet")
            : self.activeProviders.map(\.displayName).joined(separator: ", ")
        let spend = spendDashboardLedgerCostText(self.summary, currencyCode: self.currencyCode)
        return "\(day), \(L("Providers")): \(providers), \(L("Tracked tokens")): \(self.tokensText), "
            + "\(L("Requests")): \(self.requestsText), \(L("Estimated spend")): \(spend)"
    }
}

struct SpendSessionRows: View {
    let group: SpendDashboardModel.CurrencyGroup
    let hidePersonalInfo: Bool
    @State private var showsAllRows = false

    private static let collapsedRowCount = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(self.visibleRows) { row in
                let identity = row.displayIdentity(hidePersonalInfo: self.hidePersonalInfo)
                let subtitle = row.displaySubtitle(
                    hidePersonalInfo: self.hidePersonalInfo,
                    calendar: self.group.calendar)
                if row.rank > 1 {
                    Divider()
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        Text(spendDashboardRankText(row.rank))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 26, alignment: .leading)
                        SpendProviderIcon(provider: row.provider, sourceKind: .native)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(identity.name)
                                .fontWeight(.medium)
                                .lineLimit(1)
                                .help(identity.name)
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .help(subtitle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(spendDashboardMetricText(
                            cost: row.totalCost,
                            tokens: row.totalTokens,
                            currencyCode: self.group.currencyCode))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let performance = row.turnPerformance {
                        SpendSessionPerformanceView(summary: performance)
                    }
                    if let source = row.toolActivitySource {
                        SpendSessionToolActivityView(
                            source: source,
                            lastActivity: row.lastActivity,
                            range: spendToolActivityRange(group: self.group),
                            timeZone: self.group.timeZone,
                            hidePersonalInfo: self.hidePersonalInfo)
                    }
                }
                .padding(.vertical, 12)
            }
            SpendPanelExpandButton(
                rowCount: self.group.sessions.count,
                collapsedRowCount: Self.collapsedRowCount,
                showsAllRows: self.$showsAllRows)
        }
    }

    private var visibleRows: ArraySlice<SpendDashboardModel.SessionRow> {
        self.group.sessions.prefix(
            self.showsAllRows ? self.group.sessions.count : Self.collapsedRowCount)
    }
}

private struct SpendDashboardSourceFilter: View {
    @Bindable var settings: SettingsStore
    let model: SpendDashboardModel

    var body: some View {
        let ids = self.sourceIDs
        if !ids.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Sources")).font(.caption).foregroundStyle(.secondary)
                ForEach(ids, id: \.self) { sourceID in
                    Toggle(isOn: self.visibilityBinding(sourceID)) {
                        Text(self.label(for: sourceID)).lineLimit(1)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                }
            }
        }
    }

    private var sourceIDs: [String] {
        self.model.availableSources.map(\.id)
    }

    private func label(for sourceID: String) -> String {
        self.model.availableSources.first { $0.id == sourceID }?.displayName ?? sourceID
    }

    private func visibilityBinding(_ sourceID: String) -> Binding<Bool> {
        Binding(
            get: { !self.settings.spendDashboardHiddenSourceIDs.contains(sourceID) },
            set: { isVisible in
                var hidden = Set(self.settings.spendDashboardHiddenSourceIDs)
                if isVisible {
                    hidden.remove(sourceID)
                } else {
                    hidden.insert(sourceID)
                }
                self.settings.spendDashboardHiddenSourceIDs = Array(hidden)
            })
    }
}

struct SpendDashboardExportPayload: Encodable, Sendable {
    let requestedDays: Int
    let selectedDay: Date?
    let groups: [Group]
    let hiddenSourceIDs: [String]

    struct Group: Encodable, Sendable {
        let currencyCode: String
        let totalTokens: Int?
        let totalCost: Double?
        let incompleteRequestCount: Int?
        let meteredCost: Double?
        let provenance: String
        let coverage: CostUsageCoverageCounts
        let tokenMix: CostUsageTokenMix
        /// True when this group's totals are floors rather than exact values, so a consumer never
        /// mistakes a truncated or partly unpriced scan for complete history.
        let costIsLowerBound: Bool
        let tokensAreLowerBound: Bool
        let providers: [Provider]
        let models: [Model]
    }

    struct Provider: Encodable, Sendable {
        let id: String
        let displayName: String
        let sourceKind: String
        let totalTokens: Int?
        let totalCost: Double?
        let incompleteRequestCount: Int?
        let costIsLowerBound: Bool
        let tokensAreLowerBound: Bool
    }

    struct Model: Encodable, Sendable {
        let provider: String
        let modelName: String
        let totalTokens: Int?
        let totalCost: Double?
        let incompleteRequestCount: Int?
    }

    static func make(model: SpendDashboardModel, hiddenSourceIDs: [String]) -> Self {
        Self(
            requestedDays: model.requestedDays,
            selectedDay: model.selectedDay,
            groups: model.groups.map { group in
                Group(
                    currencyCode: group.currencyCode,
                    totalTokens: group.totalTokens,
                    totalCost: group.totalCost,
                    incompleteRequestCount: group.incompleteRequestCount > 0 ? group.incompleteRequestCount : nil,
                    meteredCost: group.meteredCost,
                    provenance: group.provenance.rawValue,
                    coverage: group.coverage,
                    tokenMix: group.tokenMix,
                    costIsLowerBound: group.hasPartialCost,
                    tokensAreLowerBound: group.hasPartialTokens,
                    providers: group.providers.map {
                        Provider(
                            id: $0.id,
                            displayName: $0.displayName,
                            sourceKind: $0.sourceKind.rawValue,
                            totalTokens: $0.totalTokens,
                            totalCost: $0.totalCost,
                            incompleteRequestCount: $0.incompleteRequestCount > 0 ? $0.incompleteRequestCount : nil,
                            costIsLowerBound: $0.costIsLowerBound,
                            tokensAreLowerBound: $0.tokensAreLowerBound)
                    },
                    models: group.models.map {
                        Model(
                            provider: $0.provider.rawValue,
                            modelName: $0.modelName,
                            totalTokens: $0.totalTokens,
                            totalCost: $0.totalCost,
                            incompleteRequestCount: $0.incompleteRequestCount > 0 ? $0.incompleteRequestCount : nil)
                    })
            },
            hiddenSourceIDs: hiddenSourceIDs)
    }
}

enum SpendDashboardJSONExporter {
    static func encodedData(model: SpendDashboardModel, hiddenSourceIDs: [String]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(
            SpendDashboardExportPayload.make(model: model, hiddenSourceIDs: hiddenSourceIDs))
    }

    static func defaultFilename(days: Int) -> String {
        if days >= SpendDashboardSource.scanDays {
            return "codexbar-spend-all-time.json"
        }
        return "codexbar-spend-last-\(days)-days.json"
    }

    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    @MainActor
    static func copyToPasteboard(
        model: SpendDashboardModel,
        hiddenSourceIDs: [String],
        pasteboard: NSPasteboard = .general) -> Bool
    {
        guard let data = try? self.encodedData(model: model, hiddenSourceIDs: hiddenSourceIDs),
              let json = String(bytes: data, encoding: .utf8)
        else {
            NSSound.beep()
            return false
        }
        pasteboard.clearContents()
        return pasteboard.setString(json, forType: .string)
    }

    @MainActor
    static func save(
        model: SpendDashboardModel,
        hiddenSourceIDs: [String],
        chooseDestination: ((String) -> URL?)? = nil) -> Bool
    {
        guard let data = try? self.encodedData(model: model, hiddenSourceIDs: hiddenSourceIDs) else {
            NSSound.beep()
            return false
        }
        let filename = self.defaultFilename(days: model.requestedDays)
        let url: URL?
        if let chooseDestination {
            url = chooseDestination(filename)
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = filename
            guard panel.runModal() == .OK else { return false }
            url = panel.url
        }
        guard let url else { return false }
        do {
            try self.write(data, to: url)
            return true
        } catch {
            NSSound.beep()
            return false
        }
    }
}

struct SpendDashboardPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        self.content
            .padding(16)
            .background(
                Color(nsColor: .textBackgroundColor).opacity(0.74),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.42))
            }
    }
}

func spendDashboardGroupCostText(_ group: SpendDashboardModel.CurrencyGroup) -> String {
    guard let cost = group.totalCost else { return L("Spend unavailable") }
    let formatted = UsageFormatter.currencyString(cost, currencyCode: group.currencyCode)
    return group.hasPartialCost ? "~\(formatted)" : formatted
}

func spendDashboardLedgerCostText(_ summary: SpendDashboardModel.DailySummary, currencyCode: String) -> String {
    guard let cost = summary.totalCost else { return "—" }
    let formatted = UsageFormatter.currencyString(cost, currencyCode: currencyCode)
    return summary.hasPartialCost ? "~\(formatted)" : formatted
}

func spendDashboardLedgerTokenText(_ summary: SpendDashboardModel.DailySummary) -> String {
    spendDashboardLedgerCountText(
        summary.totalTokens,
        isLowerBound: summary.hasPartialCounts,
        format: UsageFormatter.tokenCountString)
}

func spendDashboardLedgerRequestText(_ summary: SpendDashboardModel.DailySummary) -> String {
    // A missing source count makes only the request total a floor. Token totals keep their own flag.
    spendDashboardLedgerCountText(
        summary.requestCount,
        isLowerBound: summary.hasPartialCounts || summary.requestsAreLowerBound,
        format: codexBarLocalizedInteger)
}

func spendDashboardLedgerCountText(
    _ count: Int?,
    isLowerBound: Bool,
    format: (Int) -> String) -> String
{
    guard let count else { return "—" }
    let text = format(count)
    return isLowerBound ? "≥\(text)" : text
}

func spendDashboardGroupTokenText(_ group: SpendDashboardModel.CurrencyGroup) -> String {
    guard let tokens = group.totalTokens else { return "—" }
    let formatted = UsageFormatter.tokenCountString(tokens)
    return group.hasPartialTokens ? "~\(formatted)" : formatted
}

private func spendDashboardIncludesLocalHistory(_ group: SpendDashboardModel.CurrencyGroup) -> Bool {
    group.providers.contains { $0.sourceKind == .localHistory }
}

func spendDashboardProviderCountTitle(_ group: SpendDashboardModel.CurrencyGroup) -> String {
    spendDashboardIncludesLocalHistory(group) ? L("Sources") : L("Subscriptions")
}

func spendDashboardPartialSourceCoverageText(_ group: SpendDashboardModel.CurrencyGroup) -> String {
    let template = spendDashboardIncludesLocalHistory(group)
        ? "%d of %d sources have spend" : "%d of %d subscriptions have spend"
    return L(template, group.pricedProviderCount, group.providers.count)
}

func spendDashboardHistoryCaption(
    _ group: SpendDashboardModel.CurrencyGroup,
    requestedDays: Int) -> String
{
    var parts: [String] = []
    if group.hasPartialCost || group.hasPartialTokens {
        parts.append(L("Partial estimate"))
        if group.hasUnpricedProviders {
            parts.append(spendDashboardPartialSourceCoverageText(group))
        }
    } else {
        parts.append(L("Local estimated history"))
    }
    parts.append(spendDashboardCoverageText(covered: group.coveredDayCount, requested: requestedDays))
    return parts.joined(separator: " · ")
}
