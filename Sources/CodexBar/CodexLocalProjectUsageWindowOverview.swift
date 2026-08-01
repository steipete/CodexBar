import Charts
import CodexBarCore
import SwiftUI

struct CodexWorkspaceDetail<Controls: View>: View {
    let presentation: CodexLocalProjectUsageWindowPresentation
    @Binding var selectedTab: CodexLocalProjectUsageWindowTab
    let showsEstimatedCost: Bool
    let hidePersonalInfo: Bool
    let historyDays: Int
    @Binding var customHistoryDays: Int
    let isRefreshing: Bool
    let progressText: String?
    let staleMessage: String?
    @Binding var associatedSessionIDs: Set<String>?
    let setHistoryDays: (Int) -> Void
    let refresh: () -> Void
    @ViewBuilder let controls: Controls

    @AppStorage(CodexModelsRollout.featureFlagKey)
    private var modelsRevampEnabled = CodexModelsRollout.defaultEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CodexWorkspaceDetailHeader(presentation: self.presentation)
                .padding(.horizontal, CodexLocalProjectUsageWindowLayout.detailPadding)
                .padding(.top, 18)
                .padding(.bottom, 8)
            self.controls
            Divider()
            switch self.selectedTab {
            case .overview:
                CodexWorkspaceOverview(
                    presentation: self.presentation,
                    selectedTab: self.$selectedTab,
                    showsEstimatedCost: self.showsEstimatedCost)
            case .sessions:
                CodexWorkspaceSessionsTable(
                    rows: self.presentation.sessions,
                    showsEstimatedCost: self.showsEstimatedCost,
                    associatedSessionIDs: self.$associatedSessionIDs)
            case .models:
                if self.modelsRevampEnabled,
                   let payload = self.presentation.snapshot.modelsAnalytics
                {
                    CodexModelsDashboardView(
                        snapshot: payload.snapshot(workspaceID: self.presentation.selectedProject?.id),
                        scopeName: self.presentation.selectedProject?.displayName
                            ?? L("codex_workspaces_all_workspaces"),
                        showsEstimatedCost: self.showsEstimatedCost,
                        hidePersonalInfo: self.hidePersonalInfo,
                        historyDays: self.historyDays,
                        customHistoryDays: self.$customHistoryDays,
                        isRefreshing: self.isRefreshing,
                        progressText: self.progressText,
                        staleMessage: self.staleMessage,
                        setHistoryDays: self.setHistoryDays,
                        refresh: self.refresh,
                        showAssociatedSessions: { sessionIDs in
                            self.associatedSessionIDs = Set(sessionIDs)
                            self.selectedTab = .sessions
                        })
                } else {
                    CodexWorkspaceModelsTable(
                        rows: self.presentation.models,
                        totalTokens: self.presentation.displayedTokens ?? 0,
                        totalCost: self.presentation.costEstimate,
                        showsEstimatedCost: self.showsEstimatedCost)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct CodexWorkspaceDetailHeader: View {
    let presentation: CodexLocalProjectUsageWindowPresentation

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(self.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text(self.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            if let badge = self.statusBadge {
                CodexWorkspaceStatusBadge(badge: badge)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        self.presentation.selectedProject?.displayName ?? L("codex_workspaces_all_workspaces")
    }

    private var subtitle: String {
        if let project = self.presentation.selectedProject {
            guard let path = project.path else { return L("codex_workspaces_chats_description") }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        }
        return L("codex_workspaces_workspace_count", self.presentation.rankedProjects.count)
    }

    private var statusBadge: CodexWorkspaceStatusBadge.Model? {
        if self.presentation.snapshot.sourceStatus.isPartial {
            return .init(
                title: L("codex_workspaces_partial_data"),
                systemImage: "exclamationmark.triangle.fill",
                color: .orange,
                help: L("codex_workspaces_showing_last_complete_index"))
        }
        guard let project = self.presentation.selectedProject else { return nil }
        switch project.severity {
        case .high:
            return .init(
                title: L("codex_workspaces_high_usage"),
                systemImage: "exclamationmark.triangle.fill",
                color: .red,
                help: L("codex_workspaces_high_usage_help"))
        case .elevated:
            return .init(
                title: L("codex_workspaces_elevated_usage"),
                systemImage: "arrow.up.circle.fill",
                color: .orange,
                help: L("codex_workspaces_elevated_usage_help"))
        case .normal:
            return nil
        }
    }
}

private struct CodexWorkspaceStatusBadge: View {
    struct Model {
        let title: String
        let systemImage: String
        let color: Color
        let help: String
    }

    let badge: Model

    var body: some View {
        Label(self.badge.title, systemImage: self.badge.systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(self.badge.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(self.badge.color.opacity(0.1), in: Capsule())
            .help(self.badge.help)
            .accessibilityHint(self.badge.help)
    }
}

private struct CodexWorkspaceOverview: View {
    let presentation: CodexLocalProjectUsageWindowPresentation
    @Binding var selectedTab: CodexLocalProjectUsageWindowTab
    let showsEstimatedCost: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CodexLocalProjectUsageWindowLayout.sectionSpacing) {
                CodexWorkspaceMetricCards(
                    presentation: self.presentation,
                    showsEstimatedCost: self.showsEstimatedCost)
                    .padding(.horizontal, CodexLocalProjectUsageWindowLayout.detailPadding)
                CodexWorkspaceDailyUsageCard(presentation: self.presentation)
                CodexWorkspaceTopSessionsCard(
                    rows: Array(self.presentation.sessions.prefix(4)),
                    showsEstimatedCost: self.showsEstimatedCost,
                    viewAll: { self.selectedTab = .sessions })
                    .padding(.horizontal, CodexLocalProjectUsageWindowLayout.detailPadding)
                if self.presentation.consistency.hasMismatch {
                    CodexWorkspaceConsistencyNotice(consistency: self.presentation.consistency)
                        .padding(.horizontal, CodexLocalProjectUsageWindowLayout.detailPadding)
                }
            }
            .padding(.bottom, CodexLocalProjectUsageWindowLayout.detailPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CodexWorkspaceMetricCards: View {
    let presentation: CodexLocalProjectUsageWindowPresentation
    let showsEstimatedCost: Bool

    var body: some View {
        HStack(spacing: 10) {
            CodexWorkspaceMetricCard(
                title: L("codex_workspaces_tokens"),
                value: self.presentation.displayedTokens.map(UsageFormatter.tokenCountString) ?? "—",
                systemImage: "number")
            if self.showsEstimatedCost {
                CodexWorkspaceMetricCard(
                    title: L("codex_workspaces_estimated_cost_short"),
                    value: self.costText,
                    systemImage: "dollarsign.circle")
            }
            CodexWorkspaceMetricCard(
                title: L("codex_workspaces_sessions"),
                value: self.presentation.sessionCount.formatted(),
                systemImage: "text.bubble")
            CodexWorkspaceMetricCard(
                title: L("codex_workspaces_top_model"),
                value: self.presentation.topModel ?? "—",
                systemImage: "cpu")
        }
    }

    private var costText: String {
        switch self.presentation.costEstimate.coverage {
        case .known:
            UsageFormatter.currencyString(self.presentation.costEstimate.knownUSD, currencyCode: "USD")
        case .partial:
            UsageFormatter.currencyString(self.presentation.costEstimate.knownUSD, currencyCode: "USD") + "+"
        case .unavailable:
            L("codex_workspaces_cost_unavailable")
        }
    }
}

private struct CodexWorkspaceMetricCard: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(self.title, systemImage: self.systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(self.value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .modifier(CodexWorkspaceCardStyle())
        .accessibilityElement(children: .combine)
    }
}

private struct CodexWorkspaceDailyUsageCard: View {
    private static let contentPadding: CGFloat = 14

    let presentation: CodexLocalProjectUsageWindowPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            self.header
                .padding(.horizontal, self.horizontalContentInset)
            if self.presentation.daily.isEmpty {
                ContentUnavailableView(
                    L("codex_workspaces_daily_unavailable"),
                    systemImage: "chart.bar.xaxis",
                    description: Text(self.emptyDescription))
                    .frame(maxWidth: .infinity, minHeight: 138)
                    .padding(.horizontal, self.horizontalContentInset)
            } else {
                WorkspaceDailyUsageChart(
                    points: self.presentation.daily,
                    isAllWorkspaces: self.presentation.isAllWorkspaces,
                    contentInset: self.horizontalContentInset,
                    context: WorkspaceDailyUsageChartContext(
                        destinationID: self.presentation.selectedDestinationID,
                        historyDays: self.presentation.snapshot.historyDays,
                        updatedAt: self.presentation.snapshot.updatedAt))
            }
        }
        .padding(.vertical, Self.contentPadding)
        .background {
            RoundedRectangle(cornerRadius: CodexLocalProjectUsageWindowLayout.cardRadius)
                .fill(Color.primary.opacity(0.035))
                .padding(.horizontal, CodexLocalProjectUsageWindowLayout.detailPadding)
        }
        .overlay(alignment: .trailing) {
            Color(nsColor: .windowBackgroundColor)
                .frame(width: CodexLocalProjectUsageWindowLayout.detailPadding)
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: CodexLocalProjectUsageWindowLayout.cardRadius)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                .padding(.horizontal, CodexLocalProjectUsageWindowLayout.detailPadding)
        }
    }

    private var header: some View {
        HStack {
            Text(L("codex_workspaces_daily_token_usage"))
                .font(.headline)
            Spacer()
            Text(L("codex_workspaces_last_days", self.presentation.snapshot.historyDays))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var horizontalContentInset: CGFloat {
        CodexLocalProjectUsageWindowLayout.detailPadding + Self.contentPadding
    }

    private var emptyDescription: String {
        if self.presentation.consistency.dailyUnavailable {
            return L("codex_workspaces_daily_unavailable_description", self.presentation.sessionCount)
        }
        return L("codex_workspaces_no_daily_usage")
    }
}

private struct WorkspaceDailyUsageChartContext: Equatable {
    let destinationID: String
    let historyDays: Int
    let updatedAt: Date
}

private struct WorkspaceDailyUsageChart: View, @MainActor AXChartDescriptorRepresentable {
    private static let calloutWidth: CGFloat = 280
    private static let chartToCalloutSpacing: CGFloat = 12
    private static let trailingScrollSpace = Self.calloutWidth + Self.chartToCalloutSpacing
    private static let yAxisWidth: CGFloat = 60
    private static let minimumVisibleDayCount = 30
    private static let preferredDayWidth: CGFloat = 10

    let points: [WorkspaceDailyPoint]
    let isAllWorkspaces: Bool
    let contentInset: CGFloat
    let context: WorkspaceDailyUsageChartContext

    @State private var rawSelectedDate: Date?
    @State private var retainedSelectedDate: Date?
    @State private var keyboardSelectedDate: Date?
    @State private var pinnedSelectedDate: Date?
    @FocusState private var chartFocused: Bool
    @Environment(\.locale) private var locale

    var body: some View {
        GeometryReader { geometry in
            let axisScale = WorkspaceDailyUsageAxisScale(points: self.points)
            let visibleDayCount = self.visibleDayCount(for: geometry.size.width)
            let contentWidth = self.contentWidth(
                for: geometry.size.width,
                visibleDayCount: visibleDayCount)

            ScrollView(.horizontal) {
                self.chart(axisScale: axisScale)
                    .frame(width: contentWidth, height: 190)
                    .background {
                        WorkspaceHorizontalScrollerHider()
                    }
            }
            .contentMargins(
                .leading,
                self.contentInset + Self.yAxisWidth,
                for: .scrollContent)
            .contentMargins(
                .trailing,
                self.contentInset + Self.trailingScrollSpace,
                for: .scrollContent)
            .defaultScrollAnchor(.trailing)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .overlay(alignment: .trailing) {
                Group {
                    if let selectedPoint = self.selectedPoint {
                        WorkspaceDailyBreakdownCallout(
                            point: selectedPoint,
                            isAllWorkspaces: self.isAllWorkspaces,
                            isPinned: self.pinnedSelectedDate != nil)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: Self.calloutWidth, height: 190)
                .padding(.trailing, self.contentInset)
            }
            .overlay(alignment: .leading) {
                WorkspaceDailyUsageYAxisLane(
                    scale: axisScale,
                    contentInset: self.contentInset,
                    axisWidth: Self.yAxisWidth)
            }
        }
        .frame(height: 190)
        .onHover { isHovering in
            if !isHovering, self.pinnedSelectedDate == nil {
                self.clearPointerSelection()
            }
        }
        .onChange(of: self.rawSelectedDate) { _, newValue in
            guard self.pinnedSelectedDate == nil,
                  let newValue,
                  newValue != self.retainedSelectedDate
            else { return }
            self.retainedSelectedDate = newValue
        }
        .onChange(of: self.points) { _, newPoints in
            guard let selectedPoint = self.selectedPoint,
                  newPoints.contains(where: { $0.id == selectedPoint.id })
            else {
                self.clearSelection()
                return
            }
        }
        .onChange(of: self.context) {
            self.clearSelection()
        }
        .onChange(of: self.chartFocused) { _, isFocused in
            if !isFocused, self.pinnedSelectedDate == nil {
                self.keyboardSelectedDate = nil
            }
        }
    }

    private func chart(axisScale: WorkspaceDailyUsageAxisScale) -> some View {
        let selectedPoint = self.selectedPoint
        return Chart {
            ForEach(self.points) { point in
                BarMark(
                    x: .value(L("codex_workspaces_date"), point.date),
                    y: .value(L("codex_workspaces_tokens"), point.tokens))
                    .foregroundStyle(self.barColor(for: point, selectedPointID: selectedPoint?.id))
                    .cornerRadius(1.5)
            }
            if let selectedPoint {
                RuleMark(x: .value(L("codex_workspaces_date"), selectedPoint.date))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartYScale(domain: 0...axisScale.upperBound)
        .chartYAxis {
            AxisMarks(position: .leading, values: axisScale.tickValues) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) {
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartXSelection(value: self.chartSelection)
        .chartXScale(range: .plotDimension(
            startPadding: 12,
            endPadding: 24))
        .chartGesture { proxy in
            SpatialTapGesture()
                .onEnded { event in
                    guard let date: Date = proxy.value(atX: event.location.x) else { return }
                    self.togglePinnedSelection(closestTo: date)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable(interactions: .activate)
        .focused(self.$chartFocused)
        .onKeyPress(.leftArrow) {
            self.moveKeyboardSelection(.earlier) ? .handled : .ignored
        }
        .onKeyPress(.rightArrow) {
            self.moveKeyboardSelection(.later) ? .handled : .ignored
        }
        .onKeyPress(.return) {
            self.toggleKeyboardPinnedSelection() ? .handled : .ignored
        }
        .onKeyPress(.space) {
            self.toggleKeyboardPinnedSelection() ? .handled : .ignored
        }
        .onKeyPress(.escape) {
            guard self.effectiveSelectedDate != nil else { return .ignored }
            self.clearSelection()
            return .handled
        }
        .accessibilityLabel(L("codex_workspaces_daily_token_usage"))
        .accessibilityValue(self.chartAccessibilityValue)
        .accessibilityHint(L("codex_workspaces_chart_keyboard_hint"))
        .accessibilityChartDescriptor(self)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                _ = self.moveKeyboardSelection(.later)
            case .decrement:
                _ = self.moveKeyboardSelection(.earlier)
            @unknown default:
                break
            }
        }
        .accessibilityAction(named: self.pinAccessibilityActionName) {
            _ = self.toggleKeyboardPinnedSelection()
        }
    }

    func makeChartDescriptor() -> AXChartDescriptor {
        guard let first = self.points.first, let last = self.points.last else {
            return AXChartDescriptor(
                title: L("codex_workspaces_daily_token_usage"),
                summary: nil,
                xAxis: AXNumericDataAxisDescriptor(
                    title: L("codex_workspaces_date"),
                    range: 0...1,
                    gridlinePositions: []) { _ in "" },
                yAxis: AXNumericDataAxisDescriptor(
                    title: L("codex_workspaces_tokens"),
                    range: 0...1,
                    gridlinePositions: []) { UsageFormatter.tokenCountString(Int($0)) },
                additionalAxes: [],
                series: [])
        }
        let maximum = Double(self.points.map(\.tokens).max() ?? 0)
        let xAxis = AXNumericDataAxisDescriptor(
            title: L("codex_workspaces_date"),
            range: first.date.timeIntervalSinceReferenceDate...last.date.timeIntervalSinceReferenceDate,
            gridlinePositions: [])
        { value in
            Date(timeIntervalSinceReferenceDate: value)
                .formatted(.dateTime.month(.abbreviated).day().locale(self.locale))
        }
        let yAxis = AXNumericDataAxisDescriptor(
            title: L("codex_workspaces_tokens"),
            range: 0...max(1, maximum),
            gridlinePositions: []) { UsageFormatter.tokenCountString(Int($0)) }
        let series = AXDataSeriesDescriptor(
            name: L("codex_workspaces_daily_token_usage"),
            isContinuous: false,
            dataPoints: self.points.map {
                AXDataPoint(x: $0.date.timeIntervalSinceReferenceDate, y: Double($0.tokens))
            })
        return AXChartDescriptor(
            title: L("codex_workspaces_daily_token_usage"),
            summary: L("codex_workspaces_last_days", self.points.count),
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series])
    }

    private var effectiveSelectedDate: Date? {
        self.pinnedSelectedDate
            ?? self.rawSelectedDate
            ?? self.keyboardSelectedDate
            ?? self.retainedSelectedDate
    }

    private var chartSelection: Binding<Date?> {
        Binding(
            get: { self.rawSelectedDate },
            set: { newValue in
                guard self.pinnedSelectedDate == nil else { return }
                let snappedDate = newValue.flatMap { self.point(closestTo: $0)?.date }
                if snappedDate != nil {
                    self.keyboardSelectedDate = nil
                }
                guard snappedDate != self.rawSelectedDate else { return }
                self.rawSelectedDate = snappedDate
            })
    }

    private var selectedPoint: WorkspaceDailyPoint? {
        guard let date = self.effectiveSelectedDate else { return nil }
        return self.point(closestTo: date)
    }

    private var chartAccessibilityValue: String {
        guard let selectedPoint = self.selectedPoint else {
            return L("codex_workspaces_last_days", self.points.count)
        }
        let date = selectedPoint.date.formatted(
            .dateTime.year().month(.wide).day().locale(self.locale))
        return L(
            "codex_workspaces_selected_day_accessibility",
            date,
            UsageFormatter.tokenCountString(selectedPoint.tokens))
    }

    private var pinAccessibilityActionName: String {
        L(self.pinnedSelectedDate == nil
            ? "codex_workspaces_pin_selected_day"
            : "codex_workspaces_unpin_selected_day")
    }

    private func visibleDayCount(for totalWidth: CGFloat) -> Int {
        let chartWidth = max(
            0,
            totalWidth - Self.yAxisWidth - Self.trailingScrollSpace - (self.contentInset * 2))
        let widthBasedCount = max(Self.minimumVisibleDayCount, Int(chartWidth / Self.preferredDayWidth))
        guard let firstDate = self.points.first?.date, let lastDate = self.points.last?.date else {
            return widthBasedCount
        }
        let calendar = Calendar.current
        let rangeDayCount = (calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: firstDate),
            to: calendar.startOfDay(for: lastDate)).day ?? 0) + 1
        return min(max(1, rangeDayCount), widthBasedCount)
    }

    private func contentWidth(for viewportWidth: CGFloat, visibleDayCount: Int) -> CGFloat {
        let availableWidth = max(0, viewportWidth - (self.contentInset * 2))
        let rangeDayCount = self.rangeDayCount
        let requiredPlotWidth = CGFloat(max(rangeDayCount, visibleDayCount)) * Self.preferredDayWidth
        return max(availableWidth, requiredPlotWidth)
    }

    private var rangeDayCount: Int {
        guard let firstDate = self.points.first?.date, let lastDate = self.points.last?.date else { return 0 }
        let calendar = Calendar.current
        return max(
            1,
            (calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: firstDate),
                to: calendar.startOfDay(for: lastDate)).day ?? 0) + 1)
    }

    private func togglePinnedSelection(closestTo date: Date) {
        guard let candidate = self.point(closestTo: date)?.date else { return }
        self.keyboardSelectedDate = nil
        if self.pinnedSelectedDate == candidate {
            self.pinnedSelectedDate = nil
        } else {
            self.pinnedSelectedDate = candidate
            self.retainedSelectedDate = candidate
        }
    }

    private func moveKeyboardSelection(_ direction: WorkspaceDailyUsageSelectionDirection) -> Bool {
        let candidate = WorkspaceDailyUsageSelectionNavigator.movingDate(
            from: self.effectiveSelectedDate,
            direction: direction,
            availableDates: self.points.map(\.date))
        guard let candidate else { return false }

        self.rawSelectedDate = nil
        if self.pinnedSelectedDate != nil {
            self.pinnedSelectedDate = candidate
            self.retainedSelectedDate = candidate
        } else {
            self.retainedSelectedDate = nil
            self.keyboardSelectedDate = candidate
        }
        return true
    }

    private func toggleKeyboardPinnedSelection() -> Bool {
        guard let candidate = self.selectedPoint?.date ?? self.points.last?.date else { return false }
        self.rawSelectedDate = nil
        if self.pinnedSelectedDate == candidate {
            self.pinnedSelectedDate = nil
            self.retainedSelectedDate = nil
            self.keyboardSelectedDate = candidate
        } else {
            self.pinnedSelectedDate = candidate
            self.retainedSelectedDate = candidate
            self.keyboardSelectedDate = nil
        }
        return true
    }

    private func clearPointerSelection() {
        self.rawSelectedDate = nil
        self.retainedSelectedDate = nil
    }

    private func clearSelection() {
        self.rawSelectedDate = nil
        self.retainedSelectedDate = nil
        self.keyboardSelectedDate = nil
        self.pinnedSelectedDate = nil
    }

    private func point(closestTo date: Date) -> WorkspaceDailyPoint? {
        guard !self.points.isEmpty else { return nil }

        var lowerBound = 0
        var upperBound = self.points.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if self.points[midpoint].date < date {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }

        guard lowerBound > 0 else { return self.points[0] }
        guard lowerBound < self.points.count else { return self.points[self.points.count - 1] }

        let previous = self.points[lowerBound - 1]
        let next = self.points[lowerBound]
        return abs(previous.date.timeIntervalSince(date)) <= abs(next.date.timeIntervalSince(date))
            ? previous
            : next
    }

    private func barColor(for point: WorkspaceDailyPoint, selectedPointID: String?) -> Color {
        guard let selectedPointID else { return .orange.opacity(0.78) }
        return point.id == selectedPointID ? .orange : .orange.opacity(0.32)
    }
}

private struct WorkspaceHorizontalScrollerHider: NSViewRepresentable {
    func makeNSView(context: Context) -> WorkspaceHorizontalScrollerConfigurationView {
        WorkspaceHorizontalScrollerConfigurationView()
    }

    func updateNSView(_ nsView: WorkspaceHorizontalScrollerConfigurationView, context: Context) {
        nsView.scheduleConfiguration()
    }
}

private final class WorkspaceHorizontalScrollerConfigurationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.scheduleConfiguration()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        self.scheduleConfiguration()
    }

    func scheduleConfiguration() {
        DispatchQueue.main.async { [weak self] in
            guard let scrollView = self?.enclosingScrollView,
                  scrollView.hasHorizontalScroller
            else { return }
            scrollView.hasHorizontalScroller = false
        }
    }
}

private struct WorkspaceDailyUsageAxisScale: Equatable {
    let upperBound: Int
    let tickValues: [Int]

    init(points: [WorkspaceDailyPoint]) {
        let maximum = max(0, points.map(\.tokens).max() ?? 0)
        guard maximum > 0 else {
            self.upperBound = 1
            self.tickValues = [0, 1]
            return
        }

        let roughStep = Double(maximum) / 3
        let magnitude = pow(10, floor(log10(roughStep)))
        let normalizedStep = roughStep / magnitude
        let niceMultiplier: Double = if normalizedStep <= 1 {
            1
        } else if normalizedStep <= 2 {
            2
        } else if normalizedStep <= 5 {
            5
        } else {
            10
        }
        let step = max(1, Int(niceMultiplier * magnitude))
        self.upperBound = Int(ceil(Double(maximum) / Double(step))) * step
        self.tickValues = Array(stride(from: 0, through: self.upperBound, by: step))
    }
}

private struct WorkspaceDailyUsageYAxisLane: View {
    let scale: WorkspaceDailyUsageAxisScale
    let contentInset: CGFloat
    let axisWidth: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            Color(nsColor: .windowBackgroundColor)
            self.cardSurface
                .padding(.leading, CodexLocalProjectUsageWindowLayout.detailPadding)
            Chart {
                PointMark(
                    x: .value(L("codex_workspaces_date"), 0),
                    y: .value(L("codex_workspaces_tokens"), 0))
                    .foregroundStyle(.clear)
                PointMark(
                    x: .value(L("codex_workspaces_date"), 0),
                    y: .value(L("codex_workspaces_tokens"), self.scale.upperBound))
                    .foregroundStyle(.clear)
            }
            .chartYScale(domain: 0...self.scale.upperBound)
            .chartYAxis {
                AxisMarks(position: .leading, values: self.scale.tickValues) { value in
                    AxisValueLabel {
                        if let tokens = value.as(Int.self) {
                            Text(UsageFormatter.tokenCountString(tokens))
                                .font(.caption)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: [0]) {
                    AxisValueLabel {
                        Text(" ")
                            .font(.caption)
                    }
                }
            }
            .frame(width: self.axisWidth, height: 190)
            .padding(.leading, self.contentInset)
        }
        .frame(width: self.contentInset + self.axisWidth, height: 190)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var cardSurface: some View {
        Color.primary.opacity(0.035)
    }
}

private struct WorkspaceDailyBreakdownCallout: View {
    private static let visibleRowCount = 6
    private static let rowHeight: CGFloat = 21

    let point: WorkspaceDailyPoint
    let isAllWorkspaces: Bool
    let isPinned: Bool

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                self.content
                    .glassEffect(.clear.interactive(), in: .rect(cornerRadius: 9))
            } else {
                self.content
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(.quaternary, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(self.point.date.formatted(.dateTime.month(.wide).day()))
        .accessibilityValue(L(
            "codex_workspaces_daily_callout_accessibility",
            UsageFormatter.tokenCountString(self.point.tokens),
            self.countText))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if self.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(self.point.date, format: .dateTime.month(.abbreviated).day())
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                Text(UsageFormatter.tokenCountString(self.point.tokens))
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            Text(self.countText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Divider()
            self.rows
        }
        .padding(8)
        .frame(width: 280, height: 190, alignment: .topLeading)
    }

    @ViewBuilder
    private var rows: some View {
        if #available(macOS 26.0, *) {
            self.rowsScrollView
                .scrollEdgeEffectStyle(.soft, for: .top)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            self.rowsScrollView
        }
    }

    private var rowsScrollView: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(self.point.breakdownRows) { row in
                    WorkspaceDailyBreakdownCalloutRow(row: row)
                        .frame(height: Self.rowHeight)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(self.point.breakdownRows.count > Self.visibleRowCount ? .visible : .hidden)
        .contentMargins(.trailing, self.point.breakdownRows.count > Self.visibleRowCount ? 4 : 0)
        .frame(height: self.rowsHeight)
    }

    private var countText: String {
        if self.isAllWorkspaces {
            return L("codex_workspaces_workspace_count", self.point.breakdownRows.count)
        }
        return L("codex_workspaces_session_count", self.point.breakdownRows.count)
    }

    private var rowsHeight: CGFloat {
        CGFloat(min(self.point.breakdownRows.count, Self.visibleRowCount)) * Self.rowHeight
    }
}

private struct WorkspaceDailyBreakdownCalloutRow: View {
    let row: WorkspaceDailyBreakdownRow

    var body: some View {
        HStack(spacing: 10) {
            Text(self.row.title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(self.row.title)
            Spacer(minLength: 8)
            Text(self.row.tokenText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.row.title)
        .accessibilityValue(self.row.tokenText)
    }
}

private struct CodexWorkspaceTopSessionsCard: View {
    let rows: [WorkspaceSessionRow]
    let showsEstimatedCost: Bool
    let viewAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("codex_workspaces_top_sessions")).font(.headline)
                Spacer()
                Button(L("codex_workspaces_view_all_sessions"), action: self.viewAll)
                    .buttonStyle(.link)
            }
            .padding(.bottom, 10)

            if self.rows.isEmpty {
                ContentUnavailableView(
                    L("codex_workspaces_no_sessions"),
                    systemImage: "text.bubble")
                    .frame(maxWidth: .infinity, minHeight: 94)
            } else {
                CodexWorkspaceTopSessionsHeader(showsEstimatedCost: self.showsEstimatedCost)
                Divider()
                ForEach(self.rows) { row in
                    CodexWorkspaceTopSessionRow(row: row, showsEstimatedCost: self.showsEstimatedCost)
                    Divider()
                }
            }
        }
        .padding(14)
        .modifier(CodexWorkspaceCardStyle())
    }
}

private struct CodexWorkspaceTopSessionsHeader: View {
    let showsEstimatedCost: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(L("codex_workspaces_session")).frame(maxWidth: .infinity, alignment: .leading)
            Text(L("codex_workspaces_model")).frame(width: 112, alignment: .leading)
            Text(L("codex_workspaces_tokens")).frame(width: 84, alignment: .trailing)
            if self.showsEstimatedCost {
                Text(L("codex_workspaces_estimated_cost_short")).frame(width: 90, alignment: .trailing)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .frame(height: 28)
    }
}

private struct CodexWorkspaceTopSessionRow: View {
    let row: WorkspaceSessionRow
    let showsEstimatedCost: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(self.row.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(self.row.startedText + " · " + self.row.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(self.row.model).frame(width: 112, alignment: .leading).lineLimit(1)
            Text(self.row.tokenText).monospacedDigit().frame(width: 84, alignment: .trailing)
            if self.showsEstimatedCost {
                Text(Self.costText(self.row.costEstimate))
                    .monospacedDigit()
                    .frame(width: 90, alignment: .trailing)
            }
        }
        .font(.callout)
        .frame(minHeight: 42)
        .accessibilityElement(children: .combine)
    }

    static func costText(_ estimate: CodexLocalCostEstimate) -> String {
        switch estimate.coverage {
        case .known: UsageFormatter.currencyString(estimate.knownUSD, currencyCode: "USD")
        case .partial: UsageFormatter.currencyString(estimate.knownUSD, currencyCode: "USD") + "+"
        case .unavailable: L("codex_workspaces_cost_unavailable")
        }
    }
}

private struct CodexWorkspaceConsistencyNotice: View {
    let consistency: WorkspaceUsageConsistency

    var body: some View {
        Label(L("codex_workspaces_partial_breakdown_notice"), systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHint(L("codex_workspaces_partial_breakdown_help"))
    }
}

struct CodexWorkspaceCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(0.035))
            .overlay {
                RoundedRectangle(cornerRadius: CodexLocalProjectUsageWindowLayout.cardRadius)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            }
            .compositingGroup()
            .clipShape(.rect(cornerRadius: CodexLocalProjectUsageWindowLayout.cardRadius))
    }
}
