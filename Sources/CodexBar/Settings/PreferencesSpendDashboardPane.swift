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
    @State private var isExportingJSON = false
    @State private var exportDocument: SpendDashboardJSONDocument?
    @State private var detailSelections: [String: SpendDashboardDetailSection] = [:]
    @State private var sessionNavigation = SessionUsageNavigation.shared

    init(settings: SettingsStore, store: UsageStore) {
        self.settings = settings
        self.store = store
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let request = self.sessionNavigation.request {
                    HStack {
                        Text(L("Sessions")).font(.title2.weight(.semibold))
                        Spacer()
                        Button(L("Usage & Spend")) { self.sessionNavigation.request = nil }
                    }
                    SessionUsageBrowser(
                        context: request.context,
                        hidePersonalInfo: self.settings.hidePersonalInfo,
                        selectedSessionID: request.sessionID)
                        .id(request.id)
                        .frame(height: 600)
                } else {
                    self.header
                    self.refreshStatus
                    self.codexCostCatchUpPanel
                    self.content
                    self.dataControls
                }
            }
            .padding(24)
        }
        .background(FocusResigningBackground())
        .modifier(SpendDashboardToolbar(
            isVisible: self.sessionNavigation.request == nil,
            range: self.rangePicker,
            refresh: self.refreshButton,
            actions: self.actionsMenu))
        .fileExporter(
            isPresented: self.$isExportingJSON,
            document: self.exportDocument,
            contentType: .json,
            defaultFilename: SpendDashboardJSONExporter.defaultFilename(days: self.controller.model.requestedDays),
            onCompletion: { result in
                if SpendDashboardJSONDocument.exportFailed(result) {
                    NSSound.beep()
                }
                self.exportDocument = nil
            })
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

    private var detailCurrency: String {
        let preferred = self.controller.configuration?.preferredCurrencyCode ?? "auto"
        return preferred == "auto" ? "USD" : preferred
    }

    private func detailSelection(for currency: String) -> Binding<SpendDashboardDetailSection> {
        Binding(get: { self.detailSelections[currency] ?? .providers }, set: { self.detailSelections[currency] = $0 })
    }

    /// The window title names the pane; on macOS 14/15 the controls live here instead of the toolbar.
    @ViewBuilder
    var header: some View {
        if !self.showsControlsInToolbar {
            HStack(spacing: 10) {
                self.rangePicker
                    .fixedSize()
                Spacer(minLength: 8)
                self.refreshButton
                self.actionsMenu
                    .fixedSize()
            }
            .labelStyle(.iconOnly)
        }
    }

    /// macOS 26+ uses the system split view toolbar; the hand-built macOS 14/15 window keeps it inline.
    private var showsControlsInToolbar: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return true
    }

    /// A menu labelled with the current range, so the control resizes to the selection.
    private var rangePicker: some View {
        Menu {
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
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(self.selectedPeriodTitle)
        }
        .help(L("Time range"))
        .accessibilityLabel(L("Time range"))
        .accessibilityValue(self.selectedPeriodTitle)
        .accessibilityIdentifier("spend-dashboard-range-picker")
    }

    private var selectedPeriodTitle: String {
        switch self.controller.selectedPeriod {
        case let .rolling(days): spendDashboardDayRangeText(days)
        case .monthToDate: L("Month to date")
        case .allTime: L("All")
        }
    }

    private var refreshButton: some View {
        Button {
            self.store.refreshSpendDashboard(accounts: self.codexSpendScanRequests)
        } label: {
            if self.controller.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label(L("Refresh"), systemImage: "arrow.clockwise")
            }
        }
        .help(L("Refresh"))
        .disabled(self.controller.isRefreshing || !self.settings.costUsageEnabled)
    }

    private var actionsMenu: some View {
        Menu {
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
            Divider()
            Button {
                guard let payload = self.sharePayload else { return }
                ShareStatsPresenter.shared.present(payload: payload)
            } label: {
                Label(L("Share Stats…"), systemImage: "square.and.arrow.up")
            }
            .disabled(self.sharePayload == nil)
        } label: {
            // The share glyph's arrow makes it sit low next to other toolbar symbols; lift it optically.
            Label(L("More"), systemImage: "square.and.arrow.up")
                .labelStyle(.iconOnly)
                .offset(y: -1.5)
        }
        .menuIndicator(.hidden)
        .help(L("More"))
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
        if self.settings.costUsageEnabled,
           let configuration = self.controller.configuration,
           let currency = spendDashboardCodexDetailPlaceholderCurrency(
               configuration: configuration,
               currencyCodes: self.controller.model.groups.map(\.currencyCode))
        {
            SpendDashboardDetailPanel(
                group: .init(
                    currencyCode: currency,
                    providers: [],
                    models: [],
                    dailyPoints: [],
                    totalTokens: nil,
                    totalCost: nil,
                    coveredDayCount: 0,
                    chartDomain: Date.distantPast...Date.distantPast,
                    modelHistoryCompleteness: .incomplete,
                    timeZone: self.controller.configuration?.bucketCalendar.timeZone ?? .current),
                hidePersonalInfo: self.settings.hidePersonalInfo,
                supportsCodexDetails: true,
                selection: self.detailSelection(for: currency))
        }
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
                    detailSelection: self.detailSelection(for: group.id),
                    supportsCodexDetails: self.controller.configuration?.supportsCodexDetails == true
                        && (group.currencyCode == "USD" || group.currencyCode == self.detailCurrency),
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
        SpendDashboardPanel(L("Options")) {
            VStack(alignment: .leading, spacing: 12) {
                self.provenance
                Divider()
                SpendTimeZoneControls(settings: self.settings)
                Divider()
                Label(L("List-price equivalent — not a billing receipt."), systemImage: "lock.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("spend-dashboard-data-controls")
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

    private func copyJSON() {
        _ = SpendDashboardJSONExporter.copyToPasteboard(
            model: self.controller.model,
            hiddenSourceIDs: self.settings.spendDashboardHiddenSourceIDs)
    }

    private func exportJSON() {
        guard let document = try? SpendDashboardJSONDocument(
            model: self.controller.model,
            hiddenSourceIDs: self.settings.spendDashboardHiddenSourceIDs)
        else {
            NSSound.beep()
            return
        }
        self.exportDocument = document
        self.isExportingJSON = true
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

/// Each control gets its own glass capsule so the refresh spinner never regroups its neighbours.
private struct SpendDashboardToolbar<Range: View, Refresh: View, Actions: View>: ViewModifier {
    let isVisible: Bool
    let range: Range
    let refresh: Refresh
    let actions: Actions

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.toolbar {
                if self.isVisible {
                    // Spacers stop the refresh spinner's resize from splitting a shared glass capsule.
                    ToolbarItem(placement: .primaryAction) { self.range }
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                    ToolbarItem(placement: .primaryAction) { self.refresh }
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                    ToolbarItem(placement: .primaryAction) { self.actions }
                }
            }
        } else {
            content
        }
    }
}

struct SpendDashboardJSONDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    let data: Data

    /// Encodes with the same helper as Copy JSON so both actions produce identical bytes.
    init(model: SpendDashboardModel, hiddenSourceIDs: [String]) throws {
        self.data = try SpendDashboardJSONExporter.encodedData(model: model, hiddenSourceIDs: hiddenSourceIDs)
    }

    init(fileWrapper: FileWrapper) throws {
        guard fileWrapper.isRegularFile, let data = fileWrapper.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        try self.init(fileWrapper: configuration.file)
    }

    func fileWrapper() -> FileWrapper {
        FileWrapper(regularFileWithContents: self.data)
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        self.fileWrapper()
    }

    /// Cancelling the save panel is a normal outcome, so only real write failures beep.
    static func exportFailed(_ result: Result<URL, any Error>) -> Bool {
        guard case let .failure(error) = result else { return false }
        return (error as? CocoaError)?.code != .userCancelled
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

func spendDashboardCodexDetailPlaceholderCurrency(
    configuration: SpendDashboardConfiguration,
    currencyCodes: [String]) -> String?
{
    guard configuration.supportsCodexDetails else { return nil }
    let currency = configuration.preferredCurrencyCode == "auto" ? "USD" : configuration.preferredCurrencyCode
    return currencyCodes.contains("USD") || currencyCodes.contains(currency) ? nil : currency
}

func spendDashboardAvailableDetailSections(
    hasProjects: Bool,
    hasSessions: Bool,
    hasChats: Bool = false,
    supportsCodexDetails: Bool = false) -> [SpendDashboardDetailSection]
{
    var sections: [SpendDashboardDetailSection] = [.providers]
    if supportsCodexDetails || hasProjects {
        sections.append(.projects)
    }
    if supportsCodexDetails || hasChats {
        sections.append(.chats)
    }
    if supportsCodexDetails || hasSessions {
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
    let detailSelection: Binding<SpendDashboardDetailSection>?
    let supportsCodexDetails: Bool
    @State private var selectedDetailSection: SpendDashboardDetailSection
    @State private var selectedTrendSection: SpendDashboardTrendSection

    init(
        group: SpendDashboardModel.CurrencyGroup,
        requestedDays: Int,
        hidePersonalInfo: Bool = false,
        initialDetailSection: SpendDashboardDetailSection = .providers,
        initialTrendSection: SpendDashboardTrendSection? = nil,
        detailSelection: Binding<SpendDashboardDetailSection>? = nil,
        supportsCodexDetails: Bool = false,
        onSelectDay: ((Date) -> Void)? = nil,
        onClearSelectedDay: (() -> Void)? = nil)
    {
        self.group = group
        self.detailSelection = detailSelection
        self.supportsCodexDetails = supportsCodexDetails
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
            SpendDashboardPanel {
                SpendDashboardSummary(
                    group: self.group,
                    caption: spendDashboardHistoryCaption(self.group, requestedDays: self.requestedDays),
                    onClearSelectedDay: self.onClearSelectedDay)
            }
            SpendDashboardDetailPanel(
                group: self.group,
                hidePersonalInfo: self.hidePersonalInfo,
                supportsCodexDetails: self.supportsCodexDetails,
                selection: self.detailSelection ?? self.$selectedDetailSection)
            SpendDashboardTrendPanel(
                group: self.group,
                selection: self.$selectedTrendSection,
                onSelectDay: self.onSelectDay,
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
    var supportsCodexDetails = false
    @Binding var selection: SpendDashboardDetailSection

    var body: some View {
        SpendDashboardPanel(L("Usage breakdown")) {
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
                if self.activeSection != .providers {
                    if self.group.projects.isEmpty, self.group.sessions.isEmpty {
                        Text(L("No usage breakdown data available."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if self.group.detailsExcludedFromTotals {
                        Text(L("Local Codex details; excluded from combined totals."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let updatedAt = self.group.retainedDetailUpdatedAt {
                        Text(L("Incomplete") + " · " + L(
                            "Updated %@",
                            spendDashboardLedgerDateText(updatedAt, timeZone: self.group.timeZone)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var availableSections: [SpendDashboardDetailSection] {
        spendDashboardAvailableDetailSections(
            hasProjects: self.group.projects.contains { !$0.isProjectless },
            hasSessions: !self.group.sessions.isEmpty,
            hasChats: self.group.projects.contains(where: \.isProjectless),
            supportsCodexDetails: self.supportsCodexDetails)
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
        let rows = self.rows
        let shares = spendDashboardShares(rows, cost: \.totalCost, tokens: \.totalTokens)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.prefix(self.showsAllRows ? rows.count : Self.collapsedRowCount)) { row in
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
                        if let share = shares[row.id] {
                            ProgressView(value: share)
                                .progressViewStyle(.linear)
                                .controlSize(.mini)
                                .frame(maxWidth: 220)
                                .accessibilityHidden(true)
                        }
                        if let path = identity.path,
                           row.needsPathDisambiguation(in: rows)
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
                rowCount: rows.count,
                collapsedRowCount: Self.collapsedRowCount,
                showsAllRows: self.$showsAllRows)
        }
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
        SpendDashboardPanel(L("Daily estimated spend")) {
            VStack(alignment: .leading, spacing: 0) {
                if self.group.dailySummaries.isEmpty {
                    ContentUnavailableView(
                        L("Spend unavailable"),
                        systemImage: "calendar.badge.exclamationmark")
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                        self.header
                        Divider()
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
                    .monospacedDigit()
                    SpendPanelExpandButton(
                        rowCount: self.group.dailySummaries.count,
                        collapsedRowCount: Self.collapsedRowCount,
                        showsAllRows: self.$showsAllRows)
                }
            }
        }
    }

    private var header: some View {
        GridRow {
            self.headerCell(L("Day"))
            self.headerCell(L("Providers"))
                .frame(maxWidth: .infinity, alignment: .leading)
            self.headerCell(L("Tracked tokens"))
                .gridColumnAlignment(.trailing)
            self.headerCell(L("Requests"))
                .gridColumnAlignment(.trailing)
            self.headerCell(L("Estimated spend"))
                .gridColumnAlignment(.trailing)
        }
    }

    private func headerCell(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct SpendDailyLedgerRow: View {
    let summary: SpendDashboardModel.DailySummary
    let currencyCode: String
    let timeZone: TimeZone

    var body: some View {
        GridRow {
            Text(spendDashboardLedgerDateText(self.summary.day, timeZone: self.timeZone))
                .lineLimit(1)
                .accessibilityLabel(self.accessibilityLabel)
            self.providerMix
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            Text(self.tokensText)
                .accessibilityHidden(true)
            Text(self.requestsText)
                .accessibilityHidden(true)
            Text(spendDashboardLedgerCostText(self.summary, currencyCode: self.currencyCode))
                .fontWeight(.medium)
                .accessibilityHidden(true)
        }
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
    @State private var selectedSourceID: String?

    private var sourceIDs: [String] {
        Array(Set(self.group.sessions.map(\.sourceID))).sorted()
    }

    private var sourceID: String? {
        self.selectedSourceID.flatMap { self.sourceIDs.contains($0) ? $0 : nil } ?? self.sourceIDs.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if self.sourceIDs.count > 1 {
                Picker(L("Sources"), selection: Binding(
                    get: { self.sourceID ?? "" }, set: { self.selectedSourceID = $0 }))
                {
                    ForEach(self.sourceIDs, id: \.self) { id in
                        Text(self.sourceName(id)).tag(id)
                    }
                }
            }
            if let id = self.sourceID, let context = self.context(for: id) {
                SessionUsageBrowser(context: context, hidePersonalInfo: self.hidePersonalInfo)
                    .id(id)
                    .frame(height: 600)
            } else {
                Text(L("No data available")).foregroundStyle(.secondary)
            }
        }
    }

    private func sourceName(_ id: String) -> String {
        guard let row = self.group.sessions.first(where: { $0.sourceID == id }) else { return "" }
        let provider = ProviderDescriptorRegistry.descriptor(for: row.provider).metadata.displayName
        if self.hidePersonalInfo {
            let index = (self.sourceIDs.firstIndex(of: id) ?? 0) + 1
            return self.sourceIDs.count > 1 ? "\(provider) · \(codexBarLocalizedInteger(index))" : provider
        }
        return row.sourceName ?? provider
    }

    func context(for id: String) -> SessionUsageBrowserContext? {
        let rows = self.group.sessions.filter { $0.sourceID == id }
        guard let first = rows.first else { return nil }
        // Session totals belong to the source snapshot's reporting period, independent of chart day selection.
        let range = first.reportingRange ?? self.group.chartDomain.lowerBound..<self.group.chartDomain.upperBound
        let format = Date.FormatStyle(
            date: .abbreviated,
            time: .omitted,
            locale: codexBarLocalizedLocale(),
            calendar: self.group.calendar,
            timeZone: self.group.timeZone)
        let label = first.reportingPeriod == .allTime ? L("All")
            : range.lowerBound.formatted(format) + " – "
            + range.upperBound.addingTimeInterval(-0.001).formatted(format)
        return SessionUsageBrowserContext(
            providerName: self.sourceName(id),
            windowLabel: label,
            sessions: rows.map { row in
                row.usage ?? CostUsageSessionBreakdown(
                    sessionID: row.sessionID,
                    lastActivity: row.lastActivity,
                    inputTokens: nil,
                    cachedInputTokens: nil,
                    outputTokens: nil,
                    totalTokens: row.totalTokens,
                    requestCount: nil,
                    costUSD: row.totalCost.flatMap { cost in
                        row.costMultiplier > 0 ? cost / row.costMultiplier : nil
                    },
                    modelBreakdowns: [],
                    title: row.title)
            },
            currencyCode: self.group.currencyCode,
            costMultiplier: first.costMultiplier,
            timeZone: self.group.timeZone,
            activityRange: range)
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
}

struct SpendDashboardPanel<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        if let title = self.title {
            GroupBox {
                self.paddedContent
            } label: {
                Text(title)
                    .font(.headline)
                    .padding(.bottom, 4)
            }
        } else {
            GroupBox {
                self.paddedContent
            }
        }
    }

    private var paddedContent: some View {
        self.content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
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
