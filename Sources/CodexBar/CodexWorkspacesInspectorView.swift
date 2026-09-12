import CodexBarCore
import SwiftUI

@MainActor
struct CodexWorkspacesInspectorView: View {
    @Bindable var model: CodexWorkspacesInspectorModel

    var body: some View {
        Group {
            switch CodexWorkspacePrimaryContentState.resolve(
                snapshot: self.model.snapshot,
                isRefreshing: self.model.isLoading,
                didFailInitialLoad: self.model.hasLoadFailure)
            {
            case .loading:
                self.loadingContent
            case .initialFailure:
                self.initialFailureContent
            case .completeEmpty:
                self.emptyContent
            case let .partial(snapshot):
                self.content(for: snapshot, isPartial: true)
            case let .content(snapshot):
                self.content(for: snapshot, isPartial: false)
            }
        }
    }

    private var loadingContent: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text(self.progressText)
                .foregroundStyle(.secondary)
            if let progressFraction = self.progressFraction {
                Text(progressFraction, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var initialFailureContent: some View {
        ContentUnavailableView {
            Label(L("codex_workspaces_failed_read_logs"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(L("codex_workspaces_estimated_local_logs"))
        } actions: {
            Button(L("codex_workspaces_retry"), action: self.model.load)
                .disabled(self.model.isLoading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyContent: some View {
        ContentUnavailableView {
            Label(L("codex_workspaces_no_local_usage"), systemImage: "folder.badge.questionmark")
        } description: {
            Text(L("codex_workspaces_estimated_local_logs"))
        } actions: {
            self.refreshButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(for snapshot: CodexLocalProjectUsageSnapshot, isPartial: Bool) -> some View {
        let presentation = CodexWorkspacesInspectorPresentation(
            snapshot: snapshot,
            selectedProjectID: self.model.selectedProjectID,
            projection: CodexWorkspacesInspectorPresentation.projection)

        if presentation.rankedProjects.isEmpty {
            ContentUnavailableView {
                Label(
                    L(isPartial ? "codex_workspaces_partial_data" : "codex_workspaces_no_local_usage"),
                    systemImage: isPartial ? "exclamationmark.triangle" : "folder.badge.questionmark")
            } description: {
                Text(L("codex_workspaces_estimated_local_logs"))
            } actions: {
                self.refreshButton
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            NavigationSplitView {
                self.projectSidebar(presentation)
            } detail: {
                self.projectDetail(presentation, isPartial: isPartial)
            }
            .navigationSplitViewStyle(.balanced)
            .onAppear {
                self.model.reconcileSelections(rankedProjectIDs: presentation.rankedProjects.map(\.id))
            }
            .onChange(of: snapshot) {
                self.model.reconcileSelections(rankedProjectIDs: presentation.rankedProjects.map(\.id))
            }
        }
    }

    private func projectSidebar(_ presentation: CodexWorkspacesInspectorPresentation) -> some View {
        List(selection: self.projectSelection) {
            ForEach(presentation.rankedProjects) { project in
                HStack(spacing: 8) {
                    Circle()
                        .fill(self.severityColor(project.severity))
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(L("codex_workspaces_session_count", project.sessionCount))
                            if let latestActivity = project.latestActivity {
                                Text(latestActivity, style: .relative)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(project.tokens.map(UsageFormatter.tokenCountString) ?? "—")
                            .monospacedDigit()
                        Text(self.costText(project.cost))
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .tag(project.id)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(project.accessibilityDescription)
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel(L("codex_workspaces_title"))
    }

    private func projectDetail(
        _ presentation: CodexWorkspacesInspectorPresentation,
        isPartial: Bool) -> some View
    {
        VStack(alignment: .leading, spacing: 0) {
            self.detailHeader(presentation, isPartial: isPartial)
            Divider()
            self.sessionsTable(presentation.sessions)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func detailHeader(
        _ presentation: CodexWorkspacesInspectorPresentation,
        isPartial: Bool) -> some View
    {
        let selectedProject = presentation.rankedProjects.first { $0.id == presentation.selectedProjectID }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedProject?.name ?? L("codex_workspaces_title"))
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    if let path = selectedProject?.path {
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 12)
                self.refreshButton
            }

            HStack(spacing: 16) {
                self.metric(
                    L("codex_workspaces_tokens"),
                    presentation.displayedTokens.map(UsageFormatter.tokenCountString) ?? "—")
                self.metric(L("codex_workspaces_estimated_cost_short"), self.costText(presentation.cost))
                self.metric(L("codex_workspaces_sessions"), presentation.sessions.count.formatted())
                if let topModel = presentation.topModel, !topModel.isEmpty {
                    self.metric(L("codex_workspaces_top_model"), topModel)
                }
            }

            if self.model.hidesPersonalInfo {
                Label(L("hide_personal_info_title"), systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if self.model.isLoading {
                Label(self.progressText, systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isPartial {
                Label(L("codex_workspaces_partial_data"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityHint(L("codex_workspaces_estimated_local_logs"))
            }

            if self.model.hasLoadFailure {
                Label(L("codex_workspaces_failed_read_logs"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(20)
        .accessibilityElement(children: .contain)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .lineLimit(1)
        }
    }

    private func sessionsTable(_ rows: [CodexWorkspacesSessionRow]) -> some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView(
                    L("codex_workspaces_no_sessions"),
                    systemImage: "text.bubble")
            } else {
                Table(rows, selection: self.sessionSelection) {
                    TableColumn(L("codex_workspaces_session")) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .lineLimit(1)
                            if !row.searchablePath.isEmpty {
                                Text(row.searchablePath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .width(min: 220, ideal: 340)

                    TableColumn(L("codex_workspaces_started")) { row in
                        Text(self.startedText(row.startedAt))
                            .monospacedDigit()
                    }
                    .width(min: 120, ideal: 140, max: 160)

                    TableColumn(L("codex_workspaces_model")) { row in
                        Text(row.model.isEmpty ? "—" : row.model)
                            .lineLimit(1)
                    }
                    .width(min: 100, ideal: 130, max: 160)

                    TableColumn(L("codex_workspaces_tokens")) { row in
                        Text(row.tokens.map(UsageFormatter.tokenCountString) ?? "—")
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 86, ideal: 100, max: 120)

                    TableColumn(L("codex_workspaces_estimated_cost_short")) { row in
                        Text(self.costText(row.cost))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 96, ideal: 112, max: 130)
                }
                .tableStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    private var refreshButton: some View {
        Button(action: self.model.refresh) {
            if self.model.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Label(L("codex_workspaces_refresh_usage_data"), systemImage: "arrow.clockwise")
            }
        }
        .disabled(self.model.isLoading)
        .accessibilityLabel(L("codex_workspaces_refresh_usage_data"))
        .help(L("codex_workspaces_refresh_usage_data"))
    }

    private var projectSelection: Binding<String?> {
        Binding(
            get: { self.model.selectedProjectID },
            set: { self.model.selectProject(id: $0) })
    }

    private var sessionSelection: Binding<String?> {
        Binding(
            get: { self.model.selectedSessionID },
            set: { self.model.selectSession(id: $0) })
    }

    private var progressText: String {
        guard let progress = self.model.progress else {
            return L(self.model.loadReason == .inspectorDetail
                ? "codex_workspaces_indexing_projects"
                : "codex_workspaces_indexing_local_logs")
        }

        switch progress.phase {
        case .scanningLogs:
            return L("codex_workspaces_scanning_logs")
        case .indexingProjects:
            return L("codex_workspaces_indexing_projects")
        case .saving:
            return L("codex_workspaces_saving_project_index")
        }
    }

    private var progressFraction: Double? {
        guard let progress = self.model.progress,
              progress.phase == .indexingProjects,
              let processed = progress.processedFileCount,
              let total = progress.totalFileCount,
              total > 0
        else {
            return nil
        }
        return min(1, max(0, Double(processed) / Double(total)))
    }

    private func startedText(_ date: Date?) -> String {
        date?.formatted(.dateTime.month(.abbreviated).day().hour().minute()) ?? "—"
    }

    private func costText(_ cost: CodexWorkspacesCost) -> String {
        switch cost {
        case .hidden:
            "—"
        case let .known(value):
            UsageFormatter.currencyString(value, currencyCode: "USD")
        case let .partial(knownUSD):
            UsageFormatter.currencyString(knownUSD, currencyCode: "USD") + "+"
        case .unavailable:
            L("codex_workspaces_cost_unavailable")
        }
    }

    private func severityColor(_ severity: CodexLocalUsageSeverity) -> Color {
        switch severity {
        case .normal:
            .green
        case .elevated:
            .orange
        case .high:
            .red
        }
    }
}
