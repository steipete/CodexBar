import AppKit
import CodexBarCore
import SwiftUI
import UniformTypeIdentifiers

enum CodexModelsExportScope {
    case visible
    case all
    case selected
}

enum CodexModelsPresentationCSVExporter {
    private static let protectedScopeID = "hidden_workspace"

    static func export(
        snapshot: CodexModelsAnalyticsSnapshot,
        rows: [CodexModelsRow],
        metric: CodexModelsMetric,
        hidePersonalInfo: Bool) -> String
    {
        guard hidePersonalInfo else {
            return CodexModelsCSVExporter.export(snapshot: snapshot, rows: rows, metric: metric)
        }

        let protectedRows = rows.map(Self.protectedRow)
        guard let protectedSnapshot = Self.protectedSnapshot(snapshot) else { return "" }
        return CodexModelsCSVExporter.export(
            snapshot: protectedSnapshot,
            rows: protectedRows,
            metric: metric)
    }

    static func protectedSnapshot(
        _ snapshot: CodexModelsAnalyticsSnapshot) -> CodexModelsAnalyticsSnapshot?
    {
        let copy = ProtectedSnapshot(
            snapshot: snapshot,
            rows: snapshot.rows.map(Self.protectedRow))
        guard let data = try? PropertyListEncoder().encode(copy) else { return nil }
        return try? PropertyListDecoder().decode(CodexModelsAnalyticsSnapshot.self, from: data)
    }

    private static func protectedRow(_ row: CodexModelsRow) -> CodexModelsRow {
        CodexModelsRow(
            id: row.id,
            displayName: row.displayName,
            rawAliases: row.rawAliases,
            inputTokens: row.inputTokens,
            cachedInputTokens: row.cachedInputTokens,
            outputTokens: row.outputTokens,
            reasoningTokens: row.reasoningTokens,
            totalTokens: row.totalTokens,
            share: row.share,
            sessionReferences: row.sessionReferences,
            cost: row.cost,
            previousTotalTokens: row.previousTotalTokens,
            previousCost: row.previousCost,
            previousSessionReferences: row.previousSessionReferences,
            associatedSessionIDs: nil,
            tokenComparison: row.tokenComparison,
            costComparison: row.costComparison,
            sessionReferenceComparison: row.sessionReferenceComparison)
    }

    private struct ProtectedSnapshot: Encodable {
        let scopeID: String? = CodexModelsPresentationCSVExporter.protectedScopeID
        let generatedAt: Date
        let indexRevision: String
        let currentInterval: DateInterval
        let previousInterval: DateInterval
        let currentIsComplete: Bool?
        let previousIsComplete: Bool?
        let totalTokens: Int64
        let cost: CodexModelsCost
        let activeModelCount: Int
        let previousActiveModelCount: Int?
        let newlyActiveModelCount: Int?
        let uniqueSessionCount: Int
        let sessionReferenceTotal: Int
        let previousSessionReferenceTotal: Int?
        let tokenComparison: CodexModelsComparison
        let costComparison: CodexModelsComparison
        let sessionReferenceComparison: CodexModelsComparison?
        let rows: [CodexModelsRow]
        let daily: [CodexModelsDailyBucket]
        let dailyByModel: [String: [CodexModelsDailyBucket]]
        let diagnostics: CodexModelsRolloutDiagnostics

        init(snapshot: CodexModelsAnalyticsSnapshot, rows: [CodexModelsRow]) {
            self.generatedAt = snapshot.generatedAt
            self.indexRevision = snapshot.indexRevision
            self.currentInterval = snapshot.currentInterval
            self.previousInterval = snapshot.previousInterval
            self.currentIsComplete = snapshot.currentIsComplete
            self.previousIsComplete = snapshot.previousIsComplete
            self.totalTokens = snapshot.totalTokens
            self.cost = snapshot.cost
            self.activeModelCount = snapshot.activeModelCount
            self.previousActiveModelCount = snapshot.previousActiveModelCount
            self.newlyActiveModelCount = snapshot.newlyActiveModelCount
            self.uniqueSessionCount = snapshot.uniqueSessionCount
            self.sessionReferenceTotal = snapshot.sessionReferenceTotal
            self.previousSessionReferenceTotal = snapshot.previousSessionReferenceTotal
            self.tokenComparison = snapshot.tokenComparison
            self.costComparison = snapshot.costComparison
            self.sessionReferenceComparison = snapshot.sessionReferenceComparison
            self.rows = rows
            self.daily = snapshot.daily
            self.dailyByModel = snapshot.dailyByModel
            self.diagnostics = snapshot.diagnostics
        }
    }
}

struct CodexModelsCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.commaSeparatedText]
    }

    let csv: String

    init(csv: String) {
        self.csv = csv
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        self.csv = String(bytes: data, encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(self.csv.utf8))
    }
}

private struct CodexModelsSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.placeholderString = L("codex_models_search_models")
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = context.coordinator
        return searchField
    }

    func updateNSView(_ searchField: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if searchField.stringValue != self.text { searchField.stringValue = self.text }
        if self.isFocused, searchField.window?.firstResponder !== searchField.currentEditor() {
            DispatchQueue.main.async { searchField.window?.makeFirstResponder(searchField) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: CodexModelsSearchField

        init(parent: CodexModelsSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            self.parent.text = searchField.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            self.parent.isFocused = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            self.parent.isFocused = false
        }
    }
}

enum CodexModelsFormatters {
    struct CostText {
        let primary: String
        let secondary: String?
        let accessibility: String
    }

    static func compactInteger(_ value: Int64) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    static func compactNumber(_ value: Double) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    static func currency(_ value: Decimal, code: String, compact: Bool = false) -> String {
        let locale = code.uppercased() == "USD" ? Locale(identifier: "en_US") : Locale.current
        if compact {
            let magnitude = abs(NSDecimalNumber(decimal: value).doubleValue)
            let scale: Decimal
            let suffix: String
            if magnitude >= 1_000_000_000 {
                scale = Decimal(1_000_000_000)
                suffix = L("codex_models_compact_billions_suffix")
            } else if magnitude >= 1_000_000 {
                scale = Decimal(1_000_000)
                suffix = L("codex_models_compact_millions_suffix")
            } else if magnitude >= 1000 {
                scale = Decimal(1000)
                suffix = L("codex_models_compact_thousands_suffix")
            } else {
                scale = Decimal(1)
                suffix = ""
            }
            return (value / scale).formatted(
                .currency(code: code)
                    .precision(.fractionLength(0...1))
                    .locale(locale)) + suffix
        }
        return value.formatted(
            .currency(code: code)
                .precision(.fractionLength(2))
                .locale(locale))
    }

    static func percentage(_ value: Double) -> String {
        if value > 0, value < 0.001 { return "<0.1%" }
        return value.formatted(.percent.precision(.fractionLength(0...1)))
    }

    static func compactComparison(_ comparison: CodexModelsComparison) -> String {
        switch comparison {
        case .unavailable: "—"
        case .new: L("codex_models_new")
        case .ended: L("codex_models_ended")
        case .unchanged: "0%"
        case let .percent(value):
            if value > 0, value < 0.001 {
                "+<0.1%"
            } else if value < 0, value > -0.001 {
                "−<0.1%"
            } else {
                value.formatted(.percent.precision(.fractionLength(0...1)).sign(strategy: .always()))
            }
        }
    }

    static func comparisonSentence(_ comparison: CodexModelsComparison) -> String {
        switch comparison {
        case .unavailable: return L("codex_models_previous_period_unavailable")
        case .new: return L("codex_models_new_in_period")
        case .ended: return L("codex_models_no_usage_in_period")
        case .unchanged: return L("codex_models_no_change_from_previous_period")
        case let .percent(value):
            let percentage = value.formatted(
                .percent.precision(.fractionLength(0...1)).sign(strategy: .always()))
            return L("codex_models_change_from_previous_period", percentage)
        }
    }

    static func cost(_ cost: CodexModelsCost, usageTokens: Int64) -> CostText {
        guard usageTokens > 0 else {
            return CostText(primary: "—", secondary: nil, accessibility: L("codex_models_no_usage"))
        }
        guard cost.pricedTokens > 0 else {
            return CostText(
                primary: L("Unavailable"),
                secondary: L("codex_models_no_applicable_price"),
                accessibility: L("codex_models_cost_unavailable"))
        }
        let amount = self.currency(cost.knownAmount, code: cost.currencyCode)
        if cost.unpricedTokens > 0 {
            let coverage = cost.coverage >= 0.999 ? ">99.9%" : self.percentage(cost.coverage)
            return CostText(
                primary: amount + "+",
                secondary: L("codex_models_partial_priced", coverage),
                accessibility: L("codex_models_known_cost_partial_accessibility", amount, coverage))
        }
        return CostText(
            primary: amount,
            secondary: nil,
            accessibility: L("codex_models_known_cost_fully_priced_accessibility", amount))
    }

    static func metricValue(_ row: CodexModelsRow, metric: CodexModelsMetric) -> String {
        switch metric {
        case .tokens: self.compactInteger(row.totalTokens)
        case .knownCost: self.cost(row.cost, usageTokens: row.totalTokens).primary
        case .sessionReferences: row.sessionReferences.formatted()
        }
    }

    static func fullMetricValue(_ row: CodexModelsRow, metric: CodexModelsMetric) -> String {
        switch metric {
        case .tokens: L("codex_models_token_count", row.totalTokens.formatted())
        case .knownCost: self.cost(row.cost, usageTokens: row.totalTokens).accessibility
        case .sessionReferences: L("codex_models_session_reference_count", row.sessionReferences.formatted())
        }
    }

    static func previousMetricValue(_ row: CodexModelsRow, metric: CodexModelsMetric) -> String {
        switch metric {
        case .tokens:
            return row.previousTotalTokens.map { L("codex_models_token_count", $0.formatted()) } ?? "—"
        case .knownCost:
            guard let cost = row.previousCost else { return "—" }
            return self.cost(
                cost,
                usageTokens: cost.pricedTokens + cost.unpricedTokens).primary
        case .sessionReferences:
            return row.previousSessionReferences.map {
                L("codex_models_session_reference_count", $0.formatted())
            } ?? "—"
        }
    }

    static func metricValue(_ bucket: CodexModelsDailyBucket, metric: CodexModelsMetric) -> String {
        switch metric {
        case .tokens: L("codex_models_token_count", bucket.tokens.formatted())
        case .knownCost: self.cost(bucket.cost, usageTokens: bucket.tokens).accessibility
        case .sessionReferences: L("codex_models_session_reference_count", bucket.sessionReferences.formatted())
        }
    }

    static func interval(_ interval: DateInterval) -> String {
        let end = interval.end.addingTimeInterval(-0.001)
        if Calendar.current.isDate(interval.start, inSameDayAs: end) {
            return interval.start.formatted(date: .abbreviated, time: .omitted)
        }
        let startText = interval.start.formatted(date: .abbreviated, time: .omitted)
        let endText = end.formatted(date: .abbreviated, time: .omitted)
        return "\(startText) – \(endText)"
    }
}

struct CodexModelsPrecisionTable: View {
    let model: CodexModelsDashboardModel
    let showsEstimatedCost: Bool
    let freshness: CodexModelsFreshnessState
    let showAssociatedSessions: ([String]) -> Void
    let requestExport: (CodexModelsExportScope) -> Void

    @State private var searchFocused = false

    var body: some View {
        @Bindable var model = self.model
        let visibleRows = model.visibleTableRows
        let columnProfile = CodexModelsTableColumnProfile.resolve(
            layout: model.layout,
            metric: model.metric,
            showsEstimatedCost: self.showsEstimatedCost)

        VStack(spacing: 0) {
            CodexModelsTableToolbar(
                searchText: $model.searchText,
                searchFocused: self.$searchFocused,
                optionalColumns: $model.optionalColumns,
                layout: model.layout,
                showsColumnsMenu: columnProfile.showsColumnMenu,
                visibleRowCount: visibleRows.count,
                totalRowCount: model.snapshot.rows.count,
                hasSelectedRow: model.selectedRow != nil,
                selectedModelIsHiddenBySearch: model.selectedModelIsHiddenBySearch,
                clearSearch: { model.searchText = "" },
                requestExport: self.requestExport)
            Divider()
            CodexModelsTableContent(
                model: self.model,
                rows: visibleRows,
                showsEstimatedCost: self.showsEstimatedCost,
                showAssociatedSessions: self.showAssociatedSessions,
                requestExport: self.requestExport)
            Divider()
            CodexModelsTableFooter(
                snapshot: model.snapshot,
                metric: model.metric,
                showsEstimatedCost: self.showsEstimatedCost,
                freshness: self.freshness)
        }
        .codexModelsDashboardSurface()
        .accessibilityLabel(L("codex_models_precision_table"))
        .background {
            Button(L("codex_models_focus_table_search")) { self.searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}

private struct CodexModelsTableToolbar: View {
    @Binding var searchText: String
    @Binding var searchFocused: Bool
    @Binding var optionalColumns: Set<CodexModelsOptionalColumn>

    let layout: CodexModelsDashboardModel.Layout
    let showsColumnsMenu: Bool
    let visibleRowCount: Int
    let totalRowCount: Int
    let hasSelectedRow: Bool
    let selectedModelIsHiddenBySearch: Bool
    let clearSearch: () -> Void
    let requestExport: (CodexModelsExportScope) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                self.searchField
                self.searchStatus
                Spacer(minLength: 8)
                if self.showsColumnsMenu { self.columnsMenu }
                self.exportMenu
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    self.searchField
                    self.searchStatus
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    if self.showsColumnsMenu { self.columnsMenu }
                    self.exportMenu
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, CodexModelsDashboardTokens.Spacing.large)
        .padding(.vertical, CodexModelsDashboardTokens.Spacing.medium)
        .frame(
            minHeight: self.layout == .wide
                ? CodexModelsDashboardTokens.Height.wideTableToolbar
                : nil)
    }

    private var searchField: some View {
        CodexModelsSearchField(text: self.$searchText, isFocused: self.$searchFocused)
            .frame(minWidth: 180, idealWidth: 230, maxWidth: 230, minHeight: 23)
            .accessibilityLabel(L("codex_models_search_table"))
    }

    private var searchScopeText: String {
        if self.selectedModelIsHiddenBySearch {
            return L("codex_models_selected_hidden_by_search")
        }
        let count = self.searchText.isEmpty
            ? L("codex_models_model_count", self.totalRowCount)
            : L("codex_models_visible_of_total", self.visibleRowCount, self.totalRowCount)
        return L("codex_models_search_scope", count)
    }

    private var searchStatus: some View {
        HStack(spacing: CodexModelsDashboardTokens.Spacing.small) {
            Text(self.searchScopeText)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            if self.selectedModelIsHiddenBySearch {
                Button(L("codex_models_clear_search"), action: self.clearSearch).buttonStyle(.link)
            }
        }
        .font(.caption)
    }

    private var columnsMenu: some View {
        Menu(L("codex_models_columns")) {
            ForEach(CodexModelsOptionalColumn.allCases) { column in
                Toggle(column.title, isOn: Binding(
                    get: { self.optionalColumns.contains(column) },
                    set: { visible in
                        if visible {
                            self.optionalColumns.insert(column)
                        } else {
                            self.optionalColumns.remove(column)
                        }
                    }))
            }
        }
    }

    private var exportMenu: some View {
        Menu(L("codex_models_export")) {
            Button(L("codex_models_visible_rows")) { self.requestExport(.visible) }
                .disabled(self.visibleRowCount == 0)
            Button(L("codex_models_all_rows")) { self.requestExport(.all) }
                .disabled(self.totalRowCount == 0)
            Button(L("codex_models_selected_model")) { self.requestExport(.selected) }
                .disabled(!self.hasSelectedRow)
        }
    }
}

private struct CodexModelsTableFooter: View {
    let snapshot: CodexModelsAnalyticsSnapshot
    let metric: CodexModelsMetric
    let showsEstimatedCost: Bool
    let freshness: CodexModelsFreshnessState

    var body: some View {
        let cost = CodexModelsFormatters.cost(self.snapshot.cost, usageTokens: self.snapshot.totalTokens)

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(L("codex_models_all_model_count", self.snapshot.rows.count)).fontWeight(.semibold)
                Spacer()
                Text(self.snapshotValue).monospacedDigit()
                Text("100%").monospacedDigit()
                Text(CodexModelsFormatters.compactComparison(self.snapshotComparison))
                    .monospacedDigit()
                    .help(CodexModelsFormatters.comparisonSentence(self.snapshotComparison))
                if self.showsEstimatedCost, self.metric != .knownCost {
                    Text(cost.primary).monospacedDigit()
                }
            }
            .padding(8)
            Divider()
            HStack(spacing: 6) {
                self.freshnessIndicator
                self.freshnessText
                Text(L("codex_models_local_logs_source"))
                Spacer()
                if self.showsEstimatedCost {
                    Text(cost.secondary ?? L("codex_models_fully_priced_percent"))
                }
                Text(L("codex_models_totals_reconcile"))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(8)
        }
        .font(.caption)
    }

    @ViewBuilder
    private var freshnessIndicator: some View {
        switch self.freshness {
        case .current:
            Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.green)
        case .refreshing:
            ProgressView().controlSize(.mini)
        case .stale:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var freshnessText: some View {
        switch self.freshness {
        case .current:
            Text(L(
                "codex_models_updated",
                self.snapshot.generatedAt.formatted(
                    .relative(presentation: .named).locale(codexBarLocalizedLocale()))))
        case .refreshing:
            Text(L("codex_models_refreshing_last_snapshot"))
        case let .stale(message):
            Text(L("codex_models_showing_last_snapshot")).help(message)
        }
    }

    private var snapshotValue: String {
        switch self.metric {
        case .tokens: CodexModelsFormatters.compactInteger(self.snapshot.totalTokens)
        case .knownCost:
            CodexModelsFormatters.cost(self.snapshot.cost, usageTokens: self.snapshot.totalTokens).primary
        case .sessionReferences: self.snapshot.sessionReferenceTotal.formatted()
        }
    }

    private var snapshotComparison: CodexModelsComparison {
        self.snapshot.comparison(self.metric)
    }
}

private struct CodexModelsTableContent: View {
    let model: CodexModelsDashboardModel
    let rows: [CodexModelsTableRow]
    let showsEstimatedCost: Bool
    let showAssociatedSessions: ([String]) -> Void
    let requestExport: (CodexModelsExportScope) -> Void

    var body: some View {
        self.responsiveTable
            .overlay {
                if !self.model.searchText.isEmpty, self.rows.isEmpty {
                    ContentUnavailableView {
                        Label(L("codex_models_no_matching_models"), systemImage: "magnifyingglass")
                    } description: {
                        Text(L("codex_models_search_empty_description"))
                    } actions: {
                        Button(L("codex_models_clear_search")) { self.model.searchText = "" }
                    }
                    .background(.background.opacity(0.94))
                }
            }
    }

    @ViewBuilder
    private var responsiveTable: some View {
        if #available(macOS 14.4, *) {
            let profile = CodexModelsTableColumnProfile.resolve(
                layout: self.model.layout,
                metric: self.model.metric,
                showsEstimatedCost: self.showsEstimatedCost)
            self.table(
                showSessionReferences: profile.showsSessionReferences,
                showDelta: profile.showsDelta,
                showCost: profile.showsKnownCost)
        } else {
            self.compatibilityTable
        }
    }

    @available(macOS 14.4, *)
    private func table(
        showSessionReferences: Bool,
        showDelta: Bool,
        showCost: Bool) -> some View
    {
        @Bindable var model = self.model
        return Table(self.rows, selection: $model.selectedModelID, sortOrder: $model.sortOrder) {
            TableColumn(L("codex_models_model"), value: \CodexModelsTableRow.modelSort) { tableRow in
                self.modelCell(tableRow.row)
            }
            .width(min: 160, ideal: 235)

            switch model.metric {
            case .tokens:
                TableColumn(L("codex_models_tokens"), value: \CodexModelsTableRow.tokensSort) { tableRow in
                    self.valueCell(CodexModelsFormatters.compactInteger(tableRow.row.totalTokens), row: tableRow.row)
                        .help(L("codex_models_token_count", tableRow.row.totalTokens.formatted()))
                }
                .width(min: 90, ideal: 115)
            case .knownCost:
                TableColumn(L("codex_models_known_cost"), value: \CodexModelsTableRow.costSort) { tableRow in
                    self.costCell(tableRow.row)
                }
                .width(min: 115, ideal: 145)
            case .sessionReferences:
                TableColumn(
                    L("codex_models_session_refs"),
                    value: \CodexModelsTableRow.sessionReferencesSort)
                { tableRow in
                    self.valueCell(tableRow.row.sessionReferences.formatted(), row: tableRow.row)
                }
                .width(min: 90, ideal: 110)
            }

            TableColumn(L("codex_models_share"), value: \CodexModelsTableRow.shareSort) { tableRow in
                self.valueCell(CodexModelsFormatters.percentage(tableRow.share), row: tableRow.row)
                    .help(self.shareHelp)
            }
            .width(min: 70, ideal: 86)

            if showSessionReferences,
               model.metric != .sessionReferences,
               model.optionalColumns.contains(.sessionReferences)
            {
                TableColumn(
                    L("codex_models_session_refs"),
                    value: \CodexModelsTableRow.sessionReferencesSort)
                { tableRow in
                    self.valueCell(tableRow.row.sessionReferences.formatted(), row: tableRow.row)
                }
                .width(min: 86, ideal: 105)
            }
            if showDelta, model.optionalColumns.contains(.delta) {
                TableColumn(L("codex_models_delta_vs_prior"), value: \CodexModelsTableRow.deltaSort) { tableRow in
                    self.valueCell(
                        CodexModelsFormatters.compactComparison(tableRow.row.comparison(model.metric)),
                        row: tableRow.row)
                        .help(CodexModelsFormatters.comparisonSentence(tableRow.row.comparison(model.metric)))
                }
                .width(min: 72, ideal: 88)
            }
            if showCost,
               self.showsEstimatedCost,
               model.metric != .knownCost
            {
                TableColumn(L("codex_models_known_cost"), value: \CodexModelsTableRow.costSort) { tableRow in
                    self.costCell(tableRow.row)
                }
                .width(min: 115, ideal: 145)
            }
        }
        .tableStyle(.inset)
        .frame(minHeight: CodexModelsDashboardTokens.Height.table)
        .contextMenu(forSelectionType: String.self) { selectedIDs in
            self.rowContextMenu(selectedIDs)
        }
    }

    @ViewBuilder
    private var compatibilityTable: some View {
        switch self.model.metric {
        case .tokens:
            self.compatibilityTokensTable
        case .knownCost:
            self.compatibilityCostTable
        case .sessionReferences:
            self.compatibilitySessionTable
        }
    }

    private var compatibilityTokensTable: some View {
        @Bindable var model = self.model
        return Table(self.rows, selection: $model.selectedModelID, sortOrder: $model.sortOrder) {
            TableColumn(L("codex_models_model"), value: \CodexModelsTableRow.modelSort) { self.modelCell($0.row) }
            TableColumn(L("codex_models_tokens"), value: \CodexModelsTableRow.tokensSort) {
                self.valueCell(CodexModelsFormatters.compactInteger($0.row.totalTokens), row: $0.row)
            }
            TableColumn(L("codex_models_share"), value: \CodexModelsTableRow.shareSort) {
                self.valueCell(CodexModelsFormatters.percentage($0.share), row: $0.row)
            }
        }
        .tableStyle(.inset)
        .frame(minHeight: 300)
        .contextMenu(forSelectionType: String.self) { selectedIDs in
            self.rowContextMenu(selectedIDs)
        }
    }

    private var compatibilityCostTable: some View {
        @Bindable var model = self.model
        return Table(self.rows, selection: $model.selectedModelID, sortOrder: $model.sortOrder) {
            TableColumn(L("codex_models_model"), value: \CodexModelsTableRow.modelSort) { self.modelCell($0.row) }
            TableColumn(L("codex_models_known_cost"), value: \CodexModelsTableRow.costSort) { self.costCell($0.row) }
            TableColumn(L("codex_models_share"), value: \CodexModelsTableRow.shareSort) {
                self.valueCell(CodexModelsFormatters.percentage($0.share), row: $0.row)
            }
        }
        .tableStyle(.inset)
        .frame(minHeight: 300)
        .contextMenu(forSelectionType: String.self) { selectedIDs in
            self.rowContextMenu(selectedIDs)
        }
    }

    private var compatibilitySessionTable: some View {
        @Bindable var model = self.model
        return Table(self.rows, selection: $model.selectedModelID, sortOrder: $model.sortOrder) {
            TableColumn(L("codex_models_model"), value: \CodexModelsTableRow.modelSort) { self.modelCell($0.row) }
            TableColumn(L("codex_models_session_refs"), value: \CodexModelsTableRow.sessionReferencesSort) {
                self.valueCell($0.row.sessionReferences.formatted(), row: $0.row)
            }
            TableColumn(L("codex_models_share"), value: \CodexModelsTableRow.shareSort) {
                self.valueCell(CodexModelsFormatters.percentage($0.share), row: $0.row)
            }
        }
        .tableStyle(.inset)
        .frame(minHeight: 300)
        .contextMenu(forSelectionType: String.self) { selectedIDs in
            self.rowContextMenu(selectedIDs)
        }
    }

    private func modelCell(_ row: CodexModelsRow) -> some View {
        self.rowInteraction(row) {
            HStack(spacing: 7) {
                Text(row.displayName).lineLimit(1)
                if self.model.topModel?.id == row.id {
                    Text(L("codex_models_top"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if row.rawAliases.count > 1 {
                    Text(L("codex_models_alias_count", row.rawAliases.count))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .help(L(
                "codex_models_identity_aliases_help",
                row.displayName,
                row.id,
                row.rawAliases.joined(separator: ", ")))
            .accessibilityValue(self.model.selectedModelID == row.id ? L("codex_models_selected") : "")
        }
    }

    private func valueCell(_ value: String, row: CodexModelsRow) -> some View {
        self.rowInteraction(row) {
            Text(value).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func costCell(_ row: CodexModelsRow) -> some View {
        let cost = CodexModelsFormatters.cost(row.cost, usageTokens: row.totalTokens)
        return self.rowInteraction(row) {
            Text(cost.primary).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel(cost.accessibility)
                .help([cost.primary, cost.secondary].compactMap(\.self).joined(separator: " · "))
        }
    }

    private func rowInteraction(
        _ row: CodexModelsRow,
        @ViewBuilder content: () -> some View) -> some View
    {
        content()
            .frame(maxWidth: .infinity, minHeight: 22)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func rowContextMenu(_ selectedIDs: Set<String>) -> some View {
        if let id = selectedIDs.first,
           selectedIDs.count == 1,
           let row = self.model.snapshot.rows.first(where: { $0.id == id })
        {
            CodexModelsRowContextMenu(
                row: row,
                select: { self.model.selectModel(id) },
                showAssociatedSessions: self.showAssociatedSessions,
                copy: self.copy,
                export: { self.requestExport(.selected) })
        }
    }

    private var shareHelp: String {
        if self.model.metric == .knownCost,
           self.model.snapshot.cost.unpricedTokens > 0
        {
            return L("codex_models_share_known_cost_help")
        }
        return L("codex_models_share_of", self.model.metric.shareBasisTitle)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct CodexModelsRowContextMenu: View {
    let row: CodexModelsRow
    let select: () -> Void
    let showAssociatedSessions: ([String]) -> Void
    let copy: (String) -> Void
    let export: () -> Void

    var body: some View {
        let sessionIDs = self.row.associatedSessionIDs ?? []
        Group {
            Button(L("codex_models_show_details"), action: self.select)
            Button(L("codex_models_show_associated_sessions")) {
                self.select()
                self.showAssociatedSessions(sessionIDs)
            }
            .disabled(sessionIDs.isEmpty)
            Divider()
            Button(L("codex_models_copy_canonical_model_id")) {
                self.select()
                self.copy(self.row.id)
            }
            Button(L("codex_models_copy_raw_aliases")) {
                self.select()
                self.copy(self.row.rawAliases.joined(separator: "\n"))
            }
            Divider()
            Button(L("codex_models_export_selected_model")) {
                self.select()
                self.export()
            }
        }
        .onAppear(perform: self.select)
    }
}

struct CodexModelsInspector: View {
    let row: CodexModelsRow
    let snapshot: CodexModelsAnalyticsSnapshot
    let metric: CodexModelsMetric
    let showsEstimatedCost: Bool
    let close: () -> Void
    let showAssociatedSessions: ([String]) -> Void

    @State private var showsPricingCalculation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                self.header
                    .padding(.bottom, 14)
                Divider()
                self.usage
                    .padding(.vertical, 14)
                if self.showsEstimatedCost {
                    Divider()
                    CodexModelsInspectorPricingSection(
                        cost: self.row.cost,
                        previousCost: self.row.previousCost,
                        usageTokens: self.row.totalTokens,
                        showsPricing: self.$showsPricingCalculation)
                        .padding(.vertical, 14)
                }
                Divider()
                CodexModelsInspectorIdentitySection(
                    canonicalID: self.row.id,
                    aliases: self.row.rawAliases)
                    .padding(.vertical, 14)
                Divider()
                self.interpretation
                    .padding(.vertical, 14)
                Divider()
                self.actions
                    .padding(.vertical, 14)
                Divider()
                Text(L(
                    "codex_models_generated",
                    self.snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }
            .padding(16)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(self.row.displayName).font(.title3.weight(.semibold))
                    Text(L(
                        "codex_models_selected_model_interval",
                        CodexModelsFormatters.interval(self.snapshot.currentInterval)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Close"), systemImage: "xmark", action: self.close).labelStyle(.iconOnly)
            }
        }
    }

    private var usage: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.sectionTitle(L("codex_models_usage_and_change"))
            LabeledContent(
                L("codex_models_current_metric", self.metric.localizedTitle),
                value: CodexModelsFormatters.fullMetricValue(self.row, metric: self.metric))
            LabeledContent(
                L("codex_models_previous_metric", self.metric.localizedTitle),
                value: CodexModelsFormatters.previousMetricValue(self.row, metric: self.metric))
            LabeledContent(
                L("codex_models_change"),
                value: CodexModelsFormatters.compactComparison(self.row.comparison(self.metric)))
            LabeledContent(
                L("codex_models_share"),
                value: CodexModelsFormatters.percentage(self.snapshot.share(of: self.row, metric: self.metric)))
            LabeledContent(L("codex_models_session_refs"), value: self.row.sessionReferences.formatted())
        }
        .monospacedDigit()
    }

    private var interpretation: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.sectionTitle(L("codex_models_interpretation"))
            Text(self.interpretationLines.joined(separator: " "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.sectionTitle(L("codex_models_actions"))
            Button {
                self.showAssociatedSessions(self.row.associatedSessionIDs ?? [])
            } label: { Text(L("codex_models_show_associated_sessions")).frame(maxWidth: .infinity) }
                .disabled(self.row.associatedSessionIDs?.isEmpty != false)
            Button { self.copy(self.row.id) } label: {
                Text(L("codex_models_copy_canonical_id")).frame(maxWidth: .infinity)
            }
            if self.showsEstimatedCost {
                Button { self.showsPricingCalculation = true } label: {
                    Text(L("codex_models_reveal_pricing_calculation")).frame(maxWidth: .infinity)
                }
            } else {
                Button { self.copy(self.row.rawAliases.joined(separator: "\n")) } label: {
                    Text(L("codex_models_copy_aliases")).frame(maxWidth: .infinity)
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold))
    }

    private var interpretationLines: [String] {
        var lines: [String] = []
        let share = self.snapshot.share(of: self.row, metric: self.metric)
        let shareText = CodexModelsFormatters.percentage(share)
        if share >= 0.5 {
            lines.append(L("codex_models_dominates_at", self.metric.analyticsNoun, shareText))
        } else if share >= 0.2 {
            lines.append(L("codex_models_major_contributor_at", shareText))
        }
        lines.append(CodexModelsFormatters.comparisonSentence(self.row.comparison(self.metric)) + ".")
        if self.row.sessionReferences > 0 {
            let tokensPerSession = self.row.totalTokens / Int64(self.row.sessionReferences)
            lines.append(L("codex_models_tokens_per_session_reference", tokensPerSession.formatted()))
        }
        if self.row.cost.unpricedTokens > 0 {
            let coverage = CodexModelsFormatters.percentage(self.row.cost.coverage)
            lines.append(L("codex_models_cost_conclusions_limited", coverage))
        }
        return lines
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct CodexModelsInspectorPricingSection: View {
    let cost: CodexModelsCost
    let previousCost: CodexModelsCost?
    let usageTokens: Int64
    @Binding var showsPricing: Bool

    var body: some View {
        let costText = CodexModelsFormatters.cost(self.cost, usageTokens: self.usageTokens)
        let pricedTokens = self.cost.pricedTokens.formatted()
        let unpricedTokens = self.cost.unpricedTokens.formatted()
        let pricingExplanation = L(
            "codex_models_pricing_explanation",
            costText.primary,
            pricedTokens,
            unpricedTokens)

        VStack(alignment: .leading, spacing: 8) {
            Text(L("codex_models_pricing_coverage")).font(.subheadline.weight(.semibold))
            LabeledContent(L("codex_models_known_cost"), value: costText.primary)
            LabeledContent(L("codex_models_previous_known_cost"), value: self.previousCostText)
            LabeledContent(L("codex_models_coverage"), value: CodexModelsFormatters.percentage(self.cost.coverage))
            LabeledContent(L("codex_models_currency"), value: self.cost.currencyCode)
            DisclosureGroup(L("codex_models_pricing_calculation"), isExpanded: self.$showsPricing) {
                VStack(alignment: .leading, spacing: 7) {
                    LabeledContent(L("codex_models_priced_tokens"), value: pricedTokens)
                    LabeledContent(L("codex_models_unpriced_tokens"), value: unpricedTokens)
                    Text(pricingExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 6)
            }
        }
        .monospacedDigit()
    }

    private var previousCostText: String {
        guard let previousCost else { return "—" }
        return CodexModelsFormatters.cost(
            previousCost,
            usageTokens: previousCost.pricedTokens + previousCost.unpricedTokens).primary
    }
}

private struct CodexModelsInspectorIdentitySection: View {
    let canonicalID: String
    let aliases: [String]

    @State private var showsAllAliases = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("codex_models_identity_and_aliases")).font(.subheadline.weight(.semibold))
            LabeledContent(L("codex_models_canonical_id")) { Text(self.canonicalID).font(.caption.monospaced()) }
            ForEach(Array(self.aliases.prefix(3)), id: \.self) { alias in
                Text(alias).font(.caption.monospaced())
            }
            if self.aliases.count > 3 {
                DisclosureGroup(
                    L("codex_models_more_alias_count", self.aliases.count - 3),
                    isExpanded: self.$showsAllAliases)
                {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(self.aliases.dropFirst(3)), id: \.self) { alias in
                            Text(alias).font(.caption.monospaced())
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
        .textSelection(.enabled)
    }
}
