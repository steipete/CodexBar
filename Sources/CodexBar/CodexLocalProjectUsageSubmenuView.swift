import AppKit
import CodexBarCore
import SwiftUI

enum CodexLocalProjectUsageSubmenuLayout {
    static let menuWidth: CGFloat = 520
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 10
    static let sectionSpacing: CGFloat = 9
    static let chartHeight: CGFloat = 96
    static let projectListHeight: CGFloat = 216
    static let projectRowSpacing: CGFloat = 2
    static let projectRowVerticalPadding: CGFloat = 4
    static let usageBarHeight: CGFloat = 2
}

@MainActor
struct CodexLocalProjectUsageSubmenuView: View {
    let store: UsageStore
    let settings: SettingsStore
    let width: CGFloat

    private var resolvedWidth: CGFloat {
        max(self.width, CodexLocalProjectUsageSubmenuLayout.menuWidth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CodexLocalProjectUsageSubmenuLayout.sectionSpacing) {
            self.header
            self.statusLine
            if let snapshot = self.store.codexLocalProjectUsageSnapshot {
                self.usageContent(snapshot)
            } else {
                self.emptyState
            }
            self.footer
        }
        .padding(.horizontal, CodexLocalProjectUsageSubmenuLayout.horizontalPadding)
        .padding(.vertical, CodexLocalProjectUsageSubmenuLayout.verticalPadding)
        .frame(width: self.resolvedWidth, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("codex_workspaces_title"))
                    .font(.system(size: NSFont.menuFont(ofSize: 0).pointSize, weight: .semibold))
                    .lineLimit(1)
                Text(L("codex_workspaces_estimated_local_logs"))
                    .font(.system(size: NSFont.smallSystemFontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(self.historyLabel)
                .font(.system(size: NSFont.smallSystemFontSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if self.store.codexLocalProjectUsageRefreshInFlight {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text(
                    self.store.codexLocalProjectUsageProgressSubtitle
                        ?? L("codex_workspaces_indexing_local_logs"))
                    .font(.system(size: NSFont.smallSystemFontSize))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let fraction = self.store.codexLocalProjectUsageProgressFraction {
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: NSFont.smallSystemFontSize).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } else if let snapshot = self.store.codexLocalProjectUsageSnapshot,
                  snapshot.sourceStatus.isPartial
        {
            VStack(alignment: .leading, spacing: 1) {
                Label(L("codex_workspaces_failed_some_logs"), systemImage: "exclamationmark.triangle")
                Text(L("codex_workspaces_showing_last_complete_index"))
                    .padding(.leading, 20)
            }
            .font(.system(size: NSFont.smallSystemFontSize))
            .foregroundStyle(.secondary)
        } else if self.store.codexLocalProjectUsageError != nil {
            Label(L("codex_workspaces_failed_read_logs"), systemImage: "exclamationmark.triangle")
                .font(.system(size: NSFont.smallSystemFontSize))
                .foregroundStyle(.secondary)
        } else if self.store.codexLocalProjectUsageLoadState == .stale,
                  self.store.codexLocalProjectUsageSnapshot != nil
        {
            Label(
                L("codex_workspaces_stale_status", self.updatedRelativeDescription),
                systemImage: "clock")
                .font(.system(size: NSFont.smallSystemFontSize))
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        Text(L("codex_workspaces_no_local_usage"))
            .font(.system(size: NSFont.smallSystemFontSize))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
    }

    private func usageContent(_ snapshot: CodexLocalProjectUsageSnapshot) -> some View {
        let projects = self.store.codexLocalProjectUsageRankedProjects(snapshot.projects)
        return VStack(alignment: .leading, spacing: CodexLocalProjectUsageSubmenuLayout.sectionSpacing) {
            self.kpiStrip(snapshot, projects: projects)
            Divider()
            self.dailyChart(snapshot.daily)
            Divider()
            self.projectList(projects)
        }
    }

    private func kpiStrip(
        _ snapshot: CodexLocalProjectUsageSnapshot,
        projects: [CodexLocalProjectUsage]) -> some View
    {
        HStack(spacing: 0) {
            self.metric(
                L("codex_workspaces_tokens"),
                self.store.codexLocalProjectUsageDisplayTotal(snapshot.total)
                    .map(UsageFormatter.tokenCountString) ?? L("codex_workspaces_not_available"))
            self.metricDivider
            if self.settings.codexLocalProjectUsageShowsEstimatedCost {
                self.metric(
                    L("codex_workspaces_estimated_cost_short"),
                    self.estimatedCostValue(for: projects))
                self.metricDivider
            }
            self.metric(L("codex_workspaces_sessions"), "\(snapshot.sessions.count)")
            self.metricDivider
            self.metric(L("codex_workspaces_workspaces_chats"), "\(projects.count)")
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: NSFont.smallSystemFontSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: NSFont.menuFont(ofSize: 0).pointSize, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metricDivider: some View {
        Divider()
            .frame(height: 26)
            .padding(.horizontal, 10)
    }

    private func dailyChart(_ points: [CodexLocalUsageDailyPoint]) -> some View {
        let visible = Array(points.suffix(60))
        let displayed = visible.map { self.store.codexLocalProjectUsageDailyDisplayTotal($0) }
        let maximum = max(displayed.max() ?? 0, 1)
        let availableWidth = max(self.resolvedWidth - 32, 1)
        let barWidth = max(
            2,
            min(6, (availableWidth - CGFloat(max(visible.count - 1, 0) * 2)) / CGFloat(max(visible.count, 1))))
        let branding = ProviderDescriptorRegistry.descriptor(for: .codex).branding.color
        let barColor = Color(red: branding.red, green: branding.green, blue: branding.blue)

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("codex_workspaces_daily_token_usage"))
                    .font(.system(size: NSFont.smallSystemFontSize, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(L("codex_workspaces_last_days", visible.count))
                    .font(.system(size: NSFont.smallSystemFontSize))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, point in
                    let tokens = displayed[index]
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(barColor.opacity(0.78))
                        .frame(
                            width: barWidth,
                            height: max(3, CGFloat(tokens) / CGFloat(maximum) * 62))
                        .help(L(
                            "codex_workspaces_daily_point_help",
                            point.day,
                            UsageFormatter.tokenCountString(tokens)))
                        .accessibilityLabel(L(
                            "codex_workspaces_daily_point_accessibility",
                            point.day,
                            UsageFormatter.tokenCountString(tokens)))
                }
                if visible.isEmpty {
                    Text(L("codex_workspaces_no_daily_usage"))
                        .font(.system(size: NSFont.smallSystemFontSize))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: CodexLocalProjectUsageSubmenuLayout.chartHeight, alignment: .bottomLeading)
    }

    private func projectList(_ projects: [CodexLocalProjectUsage]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("codex_workspaces_title"))
                    .font(.system(size: NSFont.smallSystemFontSize, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("\(projects.count)")
                    .font(.system(size: NSFont.smallSystemFontSize).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if projects.isEmpty {
                Text(L("codex_workspaces_no_projects_or_chats"))
                    .font(.system(size: NSFont.smallSystemFontSize))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                let maximumDisplayedTokens = max(
                    projects.compactMap { self.store.codexLocalProjectUsageDisplayTotal($0.totals) }.max() ?? 0,
                    1)
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: CodexLocalProjectUsageSubmenuLayout.projectRowSpacing) {
                        ForEach(projects) { project in
                            self.projectRow(project, maximumDisplayedTokens: maximumDisplayedTokens)
                        }
                    }
                }
                .scrollIndicators(.visible)
                .frame(height: CodexLocalProjectUsageSubmenuLayout.projectListHeight)
            }
        }
    }

    private func projectRow(_ project: CodexLocalProjectUsage, maximumDisplayedTokens: Int) -> some View {
        let tokens = self.store.codexLocalProjectUsageDisplayTotal(project.totals)
            .map(UsageFormatter.tokenCountString) ?? L("codex_workspaces_not_available")
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if project.severity != .normal {
                    Image(systemName: self.severityIcon(project.severity))
                        .imageScale(.small)
                        .foregroundStyle(self.severityColor(project.severity))
                }
                Text(project.displayName)
                    .font(.system(size: NSFont.menuFont(ofSize: 0).pointSize, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(tokens)
                    .font(.system(size: NSFont.smallSystemFontSize, weight: .semibold).monospacedDigit())
                    .foregroundStyle(self.severityColor(project.severity))
            }
            Text(self.projectPath(for: project))
                .font(.system(size: NSFont.smallSystemFontSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            self.projectUsageBar(project, maximumDisplayedTokens: maximumDisplayedTokens)
            HStack(spacing: 7) {
                if self.settings.codexLocalProjectUsageShowsEstimatedCost {
                    Text(self.estimatedCostValue(for: project.costEstimate))
                }
                Text(L("codex_workspaces_session_count", project.sessionCount))
                if let model = project.topModel {
                    Text(L("codex_workspaces_bullet_value", model))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(.system(size: NSFont.smallSystemFontSize))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, CodexLocalProjectUsageSubmenuLayout.projectRowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.projectAccessibilityLabel(project))
    }

    private func projectPath(for project: CodexLocalProjectUsage) -> String {
        if project.id == CodexLocalProjectRootResolver.chatsProjectId {
            return L("codex_workspaces_chats_description")
        }
        return project.path ?? L("codex_workspaces_chats_description")
    }

    private func projectUsageBar(
        _ project: CodexLocalProjectUsage,
        maximumDisplayedTokens: Int) -> some View
    {
        let displayedTokens = self.store.codexLocalProjectUsageDisplayTotal(project.totals) ?? 0
        let fraction = min(max(CGFloat(displayedTokens) / CGFloat(maximumDisplayedTokens), 0), 1)
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.secondary.opacity(0.18))
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(0.72))
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: CodexLocalProjectUsageSubmenuLayout.usageBarHeight)
        .accessibilityHidden(true)
    }

    private func severityIcon(_ severity: CodexLocalUsageSeverity) -> String {
        switch severity {
        case .normal:
            ""
        case .elevated:
            "arrow.up.circle.fill"
        case .high:
            "exclamationmark.triangle.fill"
        }
    }

    private func severityColor(_ severity: CodexLocalUsageSeverity) -> Color {
        switch severity {
        case .normal:
            .primary
        case .elevated:
            .orange
        case .high:
            .red
        }
    }

    private var footer: some View {
        HStack(spacing: 5) {
            if let snapshot = self.store.codexLocalProjectUsageSnapshot {
                Text(
                    L(
                        "codex_workspaces_indexed_files",
                        snapshot.updatedAt.formatted(.relative(presentation: .named)),
                        snapshot.indexedFileCount))
            } else {
                Text(L("codex_workspaces_estimated_local_logs"))
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: NSFont.smallSystemFontSize))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private var historyLabel: String {
        guard let snapshot = self.store.codexLocalProjectUsageSnapshot else { return "" }
        return L("codex_workspaces_last_days", snapshot.historyDays)
    }

    private var updatedRelativeDescription: String {
        self.store.codexLocalProjectUsageSnapshot?.updatedAt.formatted(.relative(presentation: .named)) ?? ""
    }

    private func estimatedCostValue(for projects: [CodexLocalProjectUsage]) -> String {
        let estimate = projects.reduce(into: CodexLocalCostEstimate()) { result, project in
            result = CodexLocalCostEstimate(
                knownUSD: result.knownUSD + project.costEstimate.knownUSD,
                unknownTokens: result.unknownTokens + project.costEstimate.unknownTokens)
        }
        return self.estimatedCostValue(for: estimate)
    }

    private func estimatedCostValue(for estimate: CodexLocalCostEstimate) -> String {
        let value: String = switch estimate.coverage {
        case .known:
            UsageFormatter.currencyString(estimate.knownUSD, currencyCode: "USD")
        case .partial:
            UsageFormatter.currencyString(estimate.knownUSD, currencyCode: "USD") + "+"
        case .unavailable:
            L("codex_workspaces_cost_unavailable")
        }
        return String(format: L("codex_workspaces_estimated_cost_value"), value)
    }

    private func projectAccessibilityLabel(_ project: CodexLocalProjectUsage) -> String {
        let tokens = self.store.codexLocalProjectUsageDisplayTotal(project.totals)
            .map(UsageFormatter.tokenCountString) ?? L("codex_workspaces_not_available")
        return CodexWorkspaceProjectAccessibilityDescription.make(
            projectName: project.displayName,
            tokenText: tokens,
            severity: project.severity,
            estimatedCostText: self.settings.codexLocalProjectUsageShowsEstimatedCost
                ? self.estimatedCostValue(for: project.costEstimate)
                : nil,
            session: (project.sessionCount, project.topModel))
    }
}
