import CodexBarCore
import SwiftUI

struct CodexWorkspaceSessionsTable: View {
    let rows: [WorkspaceSessionRow]
    let showsEstimatedCost: Bool
    @Binding var associatedSessionIDs: Set<String>?

    @State private var searchText = ""
    @State private var selectedModel = ""
    @State private var showsSearch = false
    @State private var selectedSessionID: WorkspaceSessionRow.ID?
    @State private var sortOrder = [KeyPathComparator(\WorkspaceSessionRow.tokens, order: .reverse)]
    @FocusState private var searchFocused: Bool

    var body: some View {
        let filteredRows = self.associatedSessionIDs.map { ids in self.rows.filter { ids.contains($0.id) } }
            ?? self.rows
        let displayedRows = CodexWorkspaceSessionRows.filteredAndSorted(
            filteredRows,
            searchText: self.searchText,
            selectedModel: self.selectedModel,
            sortOrder: self.sortOrder)

        VStack(spacing: 0) {
            self.filterBar(rowCount: displayedRows.count)
            Divider()
            if displayedRows.isEmpty {
                ContentUnavailableView.search(text: self.searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.showsEstimatedCost {
                self.tableWithCost(displayedRows)
            } else {
                self.tableWithoutCost(displayedRows)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, CodexLocalProjectUsageWindowLayout.detailPadding)
        .padding(.bottom, CodexLocalProjectUsageWindowLayout.detailPadding)
        .background {
            Button(L("codex_workspaces_search_sessions")) {
                self.showsSearch = true
                self.searchFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onChange(of: self.availableModels) { _, availableModels in
            let reconciledSelection = CodexWorkspaceSessionModelFilter.reconciledSelection(
                self.selectedModel,
                availableModels: availableModels)
            if reconciledSelection != self.selectedModel {
                self.selectedModel = reconciledSelection
            }
        }
        .onChange(of: self.associatedSessionIDs) { _, sessionIDs in
            if sessionIDs != nil { self.selectedModel = "" }
        }
    }

    private func filterBar(rowCount: Int) -> some View {
        HStack(spacing: 8) {
            if self.associatedSessionIDs != nil {
                HStack(spacing: 5) {
                    Label(
                        L("codex_workspaces_associated_with_selected_model"),
                        systemImage: "line.3.horizontal.decrease.circle.fill")
                    Button(L("Clear")) { self.associatedSessionIDs = nil }.buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if self.showsSearch {
                TextField(L("codex_workspaces_search_sessions"), text: self.$searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused(self.$searchFocused)
                    .frame(width: 240)
                Button {
                    self.searchText = ""
                    self.showsSearch = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help(L("Clear"))
            } else {
                Button {
                    self.showsSearch = true
                    self.searchFocused = true
                } label: {
                    Label(L("codex_workspaces_search_sessions"), systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Menu {
                Button(L("codex_workspaces_all_models")) { self.selectedModel = "" }
                Divider()
                ForEach(self.availableModels, id: \.self) { model in
                    Button {
                        self.selectedModel = model
                    } label: {
                        if model == self.selectedModel {
                            Label(model, systemImage: "checkmark")
                        } else {
                            Text(model)
                        }
                    }
                }
            } label: {
                Label(
                    self.selectedModel.isEmpty ? L("codex_workspaces_all_models") : self.selectedModel,
                    systemImage: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)

            Spacer()
            Text(L("codex_workspaces_session_count", rowCount))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(height: 38)
    }

    private func tableWithCost(_ rows: [WorkspaceSessionRow]) -> some View {
        Table(rows, selection: self.$selectedSessionID, sortOrder: self.$sortOrder) {
            TableColumn(L("codex_workspaces_session"), value: \WorkspaceSessionRow.title) { row in
                self.sessionCell(row)
            }
            .width(min: 260, ideal: 390)
            TableColumn(L("codex_workspaces_started"), value: \WorkspaceSessionRow.startedSortValue) { row in
                Text(row.startedText).lineLimit(1)
            }
            .width(min: 118, ideal: 138, max: 156)
            TableColumn(L("codex_workspaces_model"), value: \WorkspaceSessionRow.model) { row in
                Text(row.model).lineLimit(1)
            }
            .width(min: 96, ideal: 122, max: 150)
            TableColumn(L("codex_workspaces_tokens"), value: \WorkspaceSessionRow.tokens) { row in
                Text(row.tokenText).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 82, ideal: 94, max: 112)
            TableColumn(L("codex_workspaces_estimated_cost_short"), value: \WorkspaceSessionRow.costSortValue) { row in
                Text(Self.costText(row.costEstimate))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 86, ideal: 100, max: 118)
        }
        .tableStyle(.inset)
    }

    private func tableWithoutCost(_ rows: [WorkspaceSessionRow]) -> some View {
        Table(rows, selection: self.$selectedSessionID, sortOrder: self.$sortOrder) {
            TableColumn(L("codex_workspaces_session"), value: \WorkspaceSessionRow.title) { row in
                self.sessionCell(row)
            }
            .width(min: 300, ideal: 450)
            TableColumn(L("codex_workspaces_started"), value: \WorkspaceSessionRow.startedSortValue) { row in
                Text(row.startedText).lineLimit(1)
            }
            .width(min: 118, ideal: 138, max: 156)
            TableColumn(L("codex_workspaces_model"), value: \WorkspaceSessionRow.model) { row in
                Text(row.model).lineLimit(1)
            }
            .width(min: 96, ideal: 122, max: 150)
            TableColumn(L("codex_workspaces_tokens"), value: \WorkspaceSessionRow.tokens) { row in
                Text(row.tokenText).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 82, ideal: 94, max: 112)
        }
        .tableStyle(.inset)
    }

    private func sessionCell(_ row: WorkspaceSessionRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.title).font(.callout.weight(.medium)).lineLimit(1)
            Text(row.path)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(row.path)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var availableModels: [String] {
        Array(Set(self.rows.map(\.model).filter { $0 != "—" })).sorted()
    }

    static func costText(_ estimate: CodexLocalCostEstimate) -> String {
        switch estimate.coverage {
        case .known: UsageFormatter.currencyString(estimate.knownUSD, currencyCode: "USD")
        case .partial: UsageFormatter.currencyString(estimate.knownUSD, currencyCode: "USD") + "+"
        case .unavailable: L("codex_workspaces_cost_unavailable")
        }
    }
}

struct CodexWorkspaceModelsTable: View {
    let rows: [WorkspaceModelRow]
    let totalTokens: Int
    let totalCost: CodexLocalCostEstimate
    let showsEstimatedCost: Bool

    @State private var sortOrder = [KeyPathComparator(\WorkspaceModelRow.tokens, order: .reverse)]
    @State private var selectedModelID: WorkspaceModelRow.ID?

    var body: some View {
        VStack(spacing: 0) {
            if self.rows.isEmpty {
                ContentUnavailableView(
                    L("codex_workspaces_no_models"),
                    systemImage: "cpu")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if self.showsEstimatedCost {
                    self.tableWithCost
                } else {
                    self.tableWithoutCost
                }
                Divider()
                CodexWorkspaceModelTotalRow(
                    totalTokens: self.totalTokens,
                    totalCost: self.totalCost,
                    showsEstimatedCost: self.showsEstimatedCost)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, CodexLocalProjectUsageWindowLayout.detailPadding)
        .padding(.bottom, CodexLocalProjectUsageWindowLayout.detailPadding)
        .modifier(CodexWorkspaceCardStyle())
    }

    private var sortedRows: [WorkspaceModelRow] {
        self.rows.sorted(using: self.sortOrder)
    }

    private var tableWithCost: some View {
        Table(self.sortedRows, selection: self.$selectedModelID, sortOrder: self.$sortOrder) {
            TableColumn(L("codex_workspaces_model"), value: \WorkspaceModelRow.model) { row in
                self.modelCell(row)
            }
            .width(min: 260, ideal: 420)
            TableColumn(L("codex_workspaces_tokens"), value: \WorkspaceModelRow.tokens) { row in
                Text(row.tokenText).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 108, ideal: 130)
            TableColumn(L("codex_workspaces_percent_total"), value: \WorkspaceModelRow.percentage) { row in
                Text(row.percentText).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 108, ideal: 126)
            TableColumn(L("codex_workspaces_estimated_cost_short"), value: \WorkspaceModelRow.costSortValue) { row in
                Text(CodexWorkspaceSessionsTable.costText(row.costEstimate))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 108, ideal: 132)
        }
        .tableStyle(.inset)
    }

    private var tableWithoutCost: some View {
        Table(self.sortedRows, selection: self.$selectedModelID, sortOrder: self.$sortOrder) {
            TableColumn(L("codex_workspaces_model"), value: \WorkspaceModelRow.model) { row in
                self.modelCell(row)
            }
            .width(min: 320, ideal: 520)
            TableColumn(L("codex_workspaces_tokens"), value: \WorkspaceModelRow.tokens) { row in
                Text(row.tokenText).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 108, ideal: 130)
            TableColumn(L("codex_workspaces_percent_total"), value: \WorkspaceModelRow.percentage) { row in
                Text(row.percentText).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 108, ideal: 126)
        }
        .tableStyle(.inset)
    }

    private func modelCell(_ row: WorkspaceModelRow) -> some View {
        HStack(spacing: 10) {
            Text(row.model).font(.callout.weight(.medium)).lineLimit(1)
            GeometryReader { geometry in
                Capsule()
                    .fill(.quaternary)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.accentColor.opacity(0.7))
                            .frame(width: geometry.size.width * row.percentage)
                    }
            }
            .frame(height: 3)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.percentText)
    }
}

private struct CodexWorkspaceModelTotalRow: View {
    let totalTokens: Int
    let totalCost: CodexLocalCostEstimate
    let showsEstimatedCost: Bool

    var body: some View {
        HStack(spacing: 16) {
            Text(L("codex_workspaces_total")).fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(UsageFormatter.tokenCountString(self.totalTokens))
                .monospacedDigit()
                .frame(width: 130, alignment: .trailing)
            Text(1, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .frame(width: 126, alignment: .trailing)
            if self.showsEstimatedCost {
                Text(CodexWorkspaceSessionsTable.costText(self.totalCost))
                    .monospacedDigit()
                    .frame(width: 132, alignment: .trailing)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }
}
