import CodexBarCore
import SwiftUI
import UniformTypeIdentifiers

struct CodexModelsDashboardView: View {
    let snapshot: CodexModelsAnalyticsSnapshot
    let scopeName: String
    let showsEstimatedCost: Bool
    let hidePersonalInfo: Bool
    let historyDays: Int
    @Binding var customHistoryDays: Int
    let isRefreshing: Bool
    let progressText: String?
    let staleMessage: String?
    let setHistoryDays: (Int) -> Void
    let refresh: () -> Void
    let showAssociatedSessions: ([String]) -> Void

    @State private var model: CodexModelsDashboardModel
    @State private var exportDocument: CodexModelsCSVDocument?
    @State private var exportFilename = L("codex_models_export_default_filename")
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var selectionPresentation: CodexModelsSelectionPresentation?

    init(
        snapshot: CodexModelsAnalyticsSnapshot,
        scopeName: String,
        showsEstimatedCost: Bool,
        hidePersonalInfo: Bool,
        historyDays: Int,
        customHistoryDays: Binding<Int>,
        isRefreshing: Bool,
        progressText: String?,
        staleMessage: String?,
        setHistoryDays: @escaping (Int) -> Void,
        refresh: @escaping () -> Void,
        showAssociatedSessions: @escaping ([String]) -> Void)
    {
        self.snapshot = snapshot
        self.scopeName = scopeName
        self.showsEstimatedCost = showsEstimatedCost
        self.hidePersonalInfo = hidePersonalInfo
        self.historyDays = historyDays
        self._customHistoryDays = customHistoryDays
        self.isRefreshing = isRefreshing
        self.progressText = progressText
        self.staleMessage = staleMessage
        self.setHistoryDays = setHistoryDays
        self.refresh = refresh
        self.showAssociatedSessions = showAssociatedSessions
        self._model = State(initialValue: CodexModelsDashboardModel(snapshot: snapshot))
    }

    var body: some View {
        ScrollView {
            LazyVStack(
                alignment: .leading,
                spacing: CodexModelsDashboardTokens.sectionSpacing(for: self.model.layout))
            {
                if self.model.snapshot.rows.isEmpty {
                    VStack(spacing: 0) {
                        CodexModelsAnalyticsHeader(
                            model: self.model,
                            scopeName: self.scopeName,
                            historyDays: self.historyDays,
                            customHistoryDays: self.$customHistoryDays,
                            showsEstimatedCost: self.showsEstimatedCost,
                            isRefreshing: self.isRefreshing,
                            progressText: self.progressText,
                            staleMessage: self.staleMessage,
                            setHistoryDays: self.setHistoryDays,
                            refresh: self.refresh)
                        Divider()
                        ContentUnavailableView {
                            Label(L("codex_models_no_usage_in_range"), systemImage: "chart.bar.xaxis")
                        } description: {
                            Text(L("codex_models_no_usage_description"))
                        } actions: {
                            Button(L("codex_models_refresh_model_usage"), action: self.refresh)
                                .disabled(self.isRefreshing)
                        }
                        .frame(maxWidth: .infinity, minHeight: 320)
                    }
                    .codexModelsDashboardSurface()
                } else {
                    CodexModelsSummaryStrip(model: self.model, showsEstimatedCost: self.showsEstimatedCost)
                    VStack(spacing: 0) {
                        CodexModelsAnalyticsHeader(
                            model: self.model,
                            scopeName: self.scopeName,
                            historyDays: self.historyDays,
                            customHistoryDays: self.$customHistoryDays,
                            showsEstimatedCost: self.showsEstimatedCost,
                            isRefreshing: self.isRefreshing,
                            progressText: self.progressText,
                            staleMessage: self.staleMessage,
                            setHistoryDays: self.setHistoryDays,
                            refresh: self.refresh)
                        Divider()
                        CodexModelsAnalysis(model: self.model)
                    }
                    .codexModelsDashboardSurface()
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(L("codex_models_analytics"))
                    CodexModelsPrecisionTable(
                        model: self.model,
                        showsEstimatedCost: self.showsEstimatedCost,
                        freshness: self.freshness,
                        showAssociatedSessions: self.showAssociatedSessions,
                        requestExport: self.requestExport)
                }
            }
            .padding(CodexLocalProjectUsageWindowLayout.detailPadding)
        }
        .onGeometryChange(
            for: CGFloat.self,
            of: { $0.size.width },
            action: { width in self.model.updateLayout(width: width) })
        .inspector(isPresented: Binding(
            get: { self.model.selectedRow != nil && self.selectionPresentation == .inspector },
            set: { if !$0 { self.model.clearSelection() } }))
        {
            if let row = self.model.selectedRow {
                CodexModelsInspector(
                    row: row,
                    snapshot: self.model.snapshot,
                    metric: self.model.metric,
                    showsEstimatedCost: self.showsEstimatedCost,
                    close: self.model.clearSelection,
                    showAssociatedSessions: self.showAssociatedSessions)
                    .inspectorColumnWidth(
                        min: CodexModelsDashboardTokens.Width.inspectorMinimum,
                        ideal: CodexModelsDashboardTokens.Width.inspectorIdeal,
                        max: CodexModelsDashboardTokens.Width.inspectorMaximum)
            }
        }
        .sheet(isPresented: Binding(
                get: { self.model.selectedRow != nil && self.selectionPresentation == .sheet },
                set: { if !$0 { self.model.clearSelection() } }))
        {
            if let row = self.model.selectedRow {
                CodexModelsInspector(
                    row: row,
                    snapshot: self.model.snapshot,
                    metric: self.model.metric,
                    showsEstimatedCost: self.showsEstimatedCost,
                    close: self.model.clearSelection,
                    showAssociatedSessions: self.showAssociatedSessions)
                    .frame(
                        minWidth: 420,
                        idealWidth: 480,
                        maxWidth: 560,
                        minHeight: 520,
                        idealHeight: 640)
            }
            }
            .fileExporter(
                    isPresented: self.$isExporting,
                    document: self.exportDocument,
                    contentType: .commaSeparatedText,
                    defaultFilename: self.exportFilename)
            { result in
                if case let .failure(error) = result { self.exportError = error.localizedDescription }
                self.exportDocument = nil
                }
                .alert(L("codex_models_export_failed"), isPresented: Binding(
                        get: { self.exportError != nil },
                        set: { if !$0 { self.exportError = nil } }))
                {
                    Button(L("OK"), role: .cancel) { self.exportError = nil }
                    } message: {
                        Text(self.exportError ?? L("codex_models_unknown_export_error"))
                    }
                    .background { self.keyboardCommands }
                        .onAppear { self.model.reconcileMetric(costDisplayEnabled: self.showsEstimatedCost) }
                        .onChange(of: self.showsEstimatedCost) { _, value in
                            self.model.reconcileMetric(costDisplayEnabled: value)
                        }
                        .onChange(of: self.snapshot) { _, value in self.model.replaceSnapshot(value) }
                        .onChange(of: self.model.selectedModelID) { oldValue, newValue in
                            if oldValue == nil, newValue != nil {
                                self.selectionPresentation = .resolve(layout: self.model.layout)
                            } else if newValue == nil {
                                self.selectionPresentation = nil
                            }
                        }
    }

    private var freshness: CodexModelsFreshnessState {
        if self.isRefreshing { return .refreshing }
        if let staleMessage { return .stale(staleMessage) }
        return .current
    }

    private var keyboardCommands: some View {
        HStack {
            Button(L("codex_models_export_visible_rows")) { self.requestExport(.visible) }
                .keyboardShortcut("e", modifiers: .command)
            Button(L("codex_models_clear_selection"), action: self.model.clearSelection)
                .keyboardShortcut(.cancelAction)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func requestExport(_ scope: CodexModelsExportScope) {
        let rows = self.model.exportRows(scope)
        switch scope {
        case .visible:
            self.exportFilename = L("codex_models_export_visible_filename")
        case .all:
            self.exportFilename = L("codex_models_export_all_filename")
        case .selected:
            guard let row = rows.first else { return }
            self.exportFilename = L("codex_models_export_selected_filename", row.id)
        }
        self.exportDocument = CodexModelsCSVDocument(csv: CodexModelsPresentationCSVExporter.export(
            snapshot: self.model.snapshot,
            rows: rows,
            metric: self.model.metric,
            hidePersonalInfo: self.hidePersonalInfo))
        self.isExporting = true
    }
}

private struct CodexModelsAnalyticsHeader: View {
    let model: CodexModelsDashboardModel
    let scopeName: String
    let historyDays: Int
    @Binding var customHistoryDays: Int
    let showsEstimatedCost: Bool
    let isRefreshing: Bool
    let progressText: String?
    let staleMessage: String?
    let setHistoryDays: (Int) -> Void
    let refresh: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                self.title
                self.status
                self.metricPicker
                self.historyMenu
                self.granularityMenu
                self.refreshButton
            }
            VStack(alignment: .leading, spacing: 8) {
                self.title
                HStack(spacing: 10) {
                    self.metricPicker
                    self.historyMenu
                    self.granularityMenu
                    Spacer(minLength: 4)
                    self.refreshButton
                }
                self.status.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, CodexModelsDashboardTokens.Spacing.large)
        .padding(.vertical, self.model.layout == .wide ? 10 : CodexModelsDashboardTokens.Spacing.medium)
        .frame(
            minHeight: self.model.layout == .wide
                ? CodexModelsDashboardTokens.Height.wideAnalyticsHeader
                : nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("codex_models_analytics_controls"))
    }

    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(L("codex_models_model_usage")).font(.headline)
            Text(self.scopeName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var metricPicker: some View {
        Picker(L("codex_models_metric"), selection: Binding(
            get: { self.model.metric },
            set: { metric in self.model.setMetric(metric) }))
        {
            ForEach(CodexModelsMetric.allCases.filter { self.showsEstimatedCost || $0 != .knownCost }) { metric in
                Text(metric.localizedTitle)
                    .tag(metric)
                    .disabled(metric == .knownCost && !self.model.costMetricIsAvailable)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(self.model.costMetricIsAvailable
            ? L("codex_models_choose_metric")
            : L("codex_models_cost_unavailable_for_data"))
        .accessibilityLabel(L("codex_models_metric"))
    }

    private var historyMenu: some View {
        Menu {
            ForEach([7, 30, 60, 90, 180, 365], id: \.self) { days in
                Button { self.setHistoryDays(days) } label: {
                    if days == self.activeHistoryDays {
                        Label(self.historyTitle(days), systemImage: "checkmark")
                    } else {
                        Text(self.historyTitle(days))
                    }
                }
            }
            Divider()
            HStack {
                TextField(L("codex_models_days"), value: self.$customHistoryDays, format: .number).frame(width: 58)
                Stepper("", value: self.$customHistoryDays, in: 1...365).labelsHidden()
                Button(L("codex_models_apply")) { self.setHistoryDays(self.customHistoryDays) }
            }
        } label: {
            Text(self.historyTitle(self.activeHistoryDays))
        }
        .fixedSize()
    }

    private var granularityMenu: some View {
        Menu {
            ForEach(CodexModelsGranularityPreference.allCases) { preference in
                Button { self.model.setGranularityPreference(preference) } label: {
                    if preference == self.model.granularityPreference {
                        Label(preference.title, systemImage: "checkmark")
                    } else {
                        Text(preference.title)
                    }
                }
            }
        } label: {
            Text(self.model.granularity.localizedTitle)
        }
        .fixedSize()
        .accessibilityLabel(
            L(
                "codex_models_granularity_accessibility",
                self.model.granularityPreference.title,
                self.model.granularity.localizedTitle))
    }

    private var status: some View {
        Group {
            if self.isRefreshing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(self.progressText ?? L("codex_models_indexing_last_days", self.historyDays))
                }
            } else if let staleMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(staleMessage)
                    Button(L("codex_models_retry"), action: self.refresh).buttonStyle(.link)
                }
            } else {
                Color.clear.accessibilityHidden(true)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .frame(minWidth: 12, maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }

    private var refreshButton: some View {
        Button(action: self.refresh) { Image(systemName: "arrow.clockwise") }
            .buttonStyle(.bordered)
            .disabled(self.isRefreshing)
            .help(L("codex_models_refresh_command_help"))
            .accessibilityLabel(L("codex_models_refresh_analytics"))
    }

    private var activeHistoryDays: Int {
        let interval = self.model.snapshot.currentInterval
        let inclusiveEnd = interval.end.addingTimeInterval(-0.001)
        let start = Calendar.current.startOfDay(for: interval.start)
        let end = Calendar.current.startOfDay(for: inclusiveEnd)
        return max(1, (Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
    }

    private func historyTitle(_ days: Int) -> String {
        L("codex_models_last_days", days)
    }
}

private struct CodexModelsSummaryItem: Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let accessibilityValue: String
}

private struct CodexModelsSummaryStrip: View {
    let model: CodexModelsDashboardModel
    let showsEstimatedCost: Bool

    var body: some View {
        Group {
            switch self.model.layout {
            case .wide:
                self.summaryRow
            case .medium:
                self.summaryGrid
            case .compact:
                ViewThatFits(in: .horizontal) {
                    self.summaryGrid.frame(minWidth: 460)
                    self.summaryStack
                }
            }
        }
        .codexModelsDashboardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("codex_models_summary"))
    }

    private var summaryRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(self.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().padding(.vertical, 3) }
                self.cell(item).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var summaryGrid: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                self.cell(self.items[0]).frame(maxWidth: .infinity, alignment: .leading)
                Divider().padding(.vertical, 3)
                self.cell(self.items[1]).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().padding(.horizontal, 3)
            HStack(spacing: 0) {
                self.cell(self.items[2]).frame(maxWidth: .infinity, alignment: .leading)
                Divider().padding(.vertical, 3)
                self.cell(self.items[3]).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var summaryStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(self.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().padding(.horizontal, 3) }
                self.cell(item).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var items: [CodexModelsSummaryItem] {
        let snapshot = self.model.snapshot
        let cost = CodexModelsFormatters.cost(snapshot.cost, usageTokens: snapshot.totalTokens)
        let topModel = self.model.topModel
        let newlyActive = snapshot.newlyActiveModelCount
        let tokenAccessibility = L(
            "codex_models_value_comparison_accessibility",
            L("codex_models_token_count", snapshot.totalTokens.formatted()),
            CodexModelsFormatters.comparisonSentence(snapshot.tokenComparison))
        let topDetail = topModel.map {
            let value: String = switch self.model.metric {
            case .tokens: L("codex_models_token_count", CodexModelsFormatters.compactInteger($0.totalTokens))
            case .knownCost: CodexModelsFormatters.cost($0.cost, usageTokens: $0.totalTokens).primary
            case .sessionReferences: L("codex_models_ref_count", $0.sessionReferences.formatted())
            }
            let share = CodexModelsFormatters.percentage(snapshot.share(of: $0, metric: self.model.metric))
            return L("codex_models_value_share", value, share)
        } ?? L("codex_models_no_usage")
        let topAccessibility = topModel.map {
            let value = CodexModelsFormatters.fullMetricValue($0, metric: self.model.metric)
            return L("codex_models_name_value_accessibility", $0.displayName, value)
        } ?? L("codex_models_no_top_model")
        let costCoverage = cost.secondary ?? L("codex_models_fully_priced_percent")
        return [
            CodexModelsSummaryItem(
                id: "tokens",
                title: L("codex_models_total_tokens"),
                value: CodexModelsFormatters.compactInteger(snapshot.totalTokens),
                detail: self.summaryComparison(snapshot.tokenComparison),
                accessibilityValue: tokenAccessibility),
            CodexModelsSummaryItem(
                id: "cost",
                title: L("codex_models_known_cost"),
                value: self.showsEstimatedCost ? cost.primary : L("codex_models_hidden"),
                detail: self.showsEstimatedCost
                    ? L("codex_models_value_detail", self.summaryComparison(snapshot.costComparison), costCoverage)
                    : L("codex_models_disabled_in_settings"),
                accessibilityValue: self.showsEstimatedCost
                    ? cost.accessibility
                    : L("codex_models_cost_hidden")),
            CodexModelsSummaryItem(
                id: "top",
                title: L("codex_models_top_model"),
                value: topModel?.displayName ?? "—",
                detail: topDetail,
                accessibilityValue: topAccessibility),
            CodexModelsSummaryItem(
                id: "active",
                title: L("codex_models_active_models"),
                value: snapshot.activeModelCount.formatted(),
                detail: self.newlyActiveDetail(newlyActive),
                accessibilityValue: self.newlyActiveAccessibility(
                    activeCount: snapshot.activeModelCount,
                    newlyActiveCount: newlyActive)),
        ]
    }

    private func summaryComparison(_ comparison: CodexModelsComparison) -> String {
        comparison == .unavailable
            ? L("codex_models_previous_unavailable")
            : L("codex_models_vs_previous", CodexModelsFormatters.compactComparison(comparison))
    }

    private func newlyActiveDetail(_ count: Int?) -> String {
        guard let count else { return L("codex_models_previous_period_unavailable") }
        return count == 0
            ? L("codex_models_no_newly_active")
            : L("codex_models_newly_active_count", count)
    }

    private func newlyActiveAccessibility(activeCount: Int, newlyActiveCount: Int?) -> String {
        guard let newlyActiveCount else {
            return L("codex_models_active_count_new_unavailable", activeCount)
        }
        return L("codex_models_active_and_new_count", activeCount, newlyActiveCount)
    }

    private func cell(_ item: CodexModelsSummaryItem) -> some View {
        VStack(alignment: .leading, spacing: CodexModelsDashboardTokens.Spacing.small) {
            Text(item.title).font(.caption).foregroundStyle(.secondary)
            Text(item.value)
                .font(.system(size: 24, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
            Text(item.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.horizontal, CodexModelsDashboardTokens.Spacing.xLarge)
        .padding(.vertical, CodexModelsDashboardTokens.Spacing.large)
        .frame(minHeight: self.cellHeight, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.accessibilityValue)
    }

    private var cellHeight: CGFloat {
        switch self.model.layout {
        case .wide: CodexModelsDashboardTokens.Height.wideSummary
        case .medium: CodexModelsDashboardTokens.Height.mediumSummaryCell
        case .compact: CodexModelsDashboardTokens.Height.compactSummaryCell
        }
    }
}
