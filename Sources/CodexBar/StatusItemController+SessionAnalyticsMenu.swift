import AppKit
import CodexBarCore
import SwiftUI

private final class SessionAnalyticsMenuHostingView<Content: View>: NSHostingView<Content> {
    override var allowsVibrancy: Bool {
        true
    }
}

private enum SessionAnalyticsSummaryFocus: String, CaseIterable {
    case sessionsAnalyzed
    case medianDuration
    case medianToolCalls
    case toolFailureRate

    var title: String {
        switch self {
        case .sessionsAnalyzed: "Sessions analyzed"
        case .medianDuration: "Median duration"
        case .medianToolCalls: "Median tool calls"
        case .toolFailureRate: "Tool failure rate"
        }
    }

    func value(in snapshot: CodexSessionAnalyticsSnapshot) -> String {
        switch self {
        case .sessionsAnalyzed:
            "\(snapshot.sessionsAnalyzed)"
        case .medianDuration:
            SessionAnalyticsFormatters.durationText(snapshot.medianSessionDurationSeconds)
        case .medianToolCalls:
            SessionAnalyticsFormatters.decimalText(snapshot.medianToolCallsPerSession)
        case .toolFailureRate:
            SessionAnalyticsFormatters.percentageText(snapshot.toolFailureRate)
        }
    }
}

private struct SessionAnalyticsWindowPresetButton: View {
    let value: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            Text("\(self.value)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(self.selected ? Color.white : Color(nsColor: .labelColor))
                .frame(minWidth: 34)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(self.selected
                            ? Color(red: 0 / 255, green: 122 / 255, blue: 255 / 255)
                            : Color(nsColor: .controlBackgroundColor)))
        }
        .buttonStyle(.plain)
    }
}

private struct SessionAnalyticsWindowSelectorView: View {
    let selectedWindow: Int
    let width: CGFloat
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Window")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: .labelColor))

            HStack(spacing: 8) {
                ForEach(SettingsStore.codexSessionAnalyticsWindowPresets, id: \.self) { value in
                    SessionAnalyticsWindowPresetButton(
                        value: value,
                        selected: value == self.selectedWindow)
                    {
                        self.onSelect(value)
                    }
                }
            }

            Text("Analyzing recent \(self.selectedWindow) sessions")
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: self.width, alignment: .leading)
    }
}

private struct SessionAnalyticsMetricRowView: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(self.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(self.value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct SessionAnalyticsToolRowView: View {
    let tool: CodexToolAggregate
    let sessionsAnalyzed: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(self.tool.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(self.tool.callCount) calls")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
            }

            Text(self.secondaryText)
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var secondaryText: String {
        [
            "\(self.tool.sessionCountUsingTool)/\(self.sessionsAnalyzed) sessions",
            "\(SessionAnalyticsFormatters.percentageText(self.tool.callShare)) share",
        ].joined(separator: "  •  ")
    }
}

private struct SessionAnalyticsSessionRowView: View {
    let session: CodexSessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(self.session.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(self.session.startedAt.relativeDescription())
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
            }

            Text(self.primaryStats)
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .lineLimit(1)

            Text(self.secondaryStats)
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var primaryStats: String {
        [
            SessionAnalyticsFormatters.durationText(self.session.durationSeconds),
            "\(self.session.toolCallCount) calls",
            "\(self.session.toolFailureCount) failures",
        ].joined(separator: "  •  ")
    }

    private var secondaryStats: String {
        [
            "\(self.session.verificationAttemptCount) checks",
            self.session.tokenUsage.map {
                "\(SessionAnalyticsFormatters.compactTokenText($0.totalTokens)) tok"
            } ?? "token n/a",
        ].joined(separator: "  •  ")
    }
}

private struct SessionAnalyticsEmptyStateView: View {
    let error: String?
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No local Codex session data found.")
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))

            if let error, !error.isEmpty {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: self.width, alignment: .leading)
    }
}

private struct SessionAnalyticsDetailPanel: View {
    let title: String
    let subtitle: String?
    let lines: [(String, String)]
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(self.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(nsColor: .labelColor))
                .lineLimit(3)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(2)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(self.lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 12) {
                        Text(line.0)
                            .font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(2)

                        Text(line.1)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(nsColor: .labelColor))
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: self.width, alignment: .leading)
    }
}

private struct SessionAnalyticsChartLegendRow: View {
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(self.color)
                .frame(width: 8, height: 8)

            Text(self.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(self.value)
                .font(.system(size: 10))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .lineLimit(1)
        }
    }
}

private struct SessionAnalyticsToolShareSlice: Identifiable {
    let id: String
    let title: String
    let value: Int
    let color: Color
}

private struct SessionAnalyticsDonutSlice: Shape {
    let startAngle: Angle
    let endAngle: Angle
    let innerRadiusFraction: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) / 2
        let innerRadius = outerRadius * self.innerRadiusFraction
        let adjustedStart = self.startAngle - .degrees(90)
        let adjustedEnd = self.endAngle - .degrees(90)

        var path = Path()
        path.addArc(
            center: center,
            radius: outerRadius,
            startAngle: adjustedStart,
            endAngle: adjustedEnd,
            clockwise: false)
        path.addArc(
            center: center,
            radius: innerRadius,
            startAngle: adjustedEnd,
            endAngle: adjustedStart,
            clockwise: true)
        path.closeSubpath()
        return path
    }
}

private struct SessionAnalyticsToolShareChartView: View {
    let snapshot: CodexSessionAnalyticsSnapshot
    let width: CGFloat

    private let palette: [Color] = [
        Color(red: 64 / 255, green: 156 / 255, blue: 255 / 255),
        Color(red: 88 / 255, green: 204 / 255, blue: 167 / 255),
        Color(red: 255 / 255, green: 170 / 255, blue: 60 / 255),
        Color(red: 242 / 255, green: 99 / 255, blue: 126 / 255),
        Color(red: 145 / 255, green: 118 / 255, blue: 255 / 255),
        Color(nsColor: .tertiaryLabelColor),
    ]

    var body: some View {
        let slices = self.chartSlices
        let totalCalls = max(self.snapshot.summaryDiagnostics.totalCalls, slices.reduce(0) { $0 + $1.value })

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                        let startAngle = self.startAngle(for: index, slices: slices)
                        let endAngle = self.endAngle(for: index, slices: slices)
                        let donutSlice = SessionAnalyticsDonutSlice(
                            startAngle: startAngle,
                            endAngle: endAngle,
                            innerRadiusFraction: 0.58)
                        donutSlice.fill(slice.color)
                    }

                    VStack(spacing: 2) {
                        Text(SessionAnalyticsFormatters.compactTokenText(totalCalls))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(nsColor: .labelColor))
                        Text("tool calls")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    }
                }
                .frame(width: 92, height: 92)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(slices.prefix(5)) { slice in
                        SessionAnalyticsChartLegendRow(
                            color: slice.color,
                            title: slice.title,
                            value: self.legendValue(for: slice, totalCalls: totalCalls))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
        .frame(width: self.width, alignment: .leading)
    }

    private var chartSlices: [SessionAnalyticsToolShareSlice] {
        let topTools = Array(self.snapshot.topTools.prefix(5))
        let totalCalls = max(
            self.snapshot.summaryDiagnostics.totalCalls,
            topTools.reduce(0) { $0 + $1.callCount })
        let baseSlices = topTools.enumerated().map { index, tool in
            SessionAnalyticsToolShareSlice(
                id: tool.name,
                title: tool.name,
                value: tool.callCount,
                color: self.palette[index % self.palette.count])
        }

        let otherCalls = max(0, totalCalls - baseSlices.reduce(0) { $0 + $1.value })
        if otherCalls > 0 {
            return baseSlices + [
                SessionAnalyticsToolShareSlice(
                    id: "other",
                    title: "Other",
                    value: otherCalls,
                    color: self.palette.last ?? Color(nsColor: .tertiaryLabelColor)),
            ]
        }
        return baseSlices
    }

    private func startAngle(
        for index: Int,
        slices: [SessionAnalyticsToolShareSlice]) -> Angle
    {
        let total = max(1, slices.reduce(0) { $0 + $1.value })
        let preceding = slices.prefix(index).reduce(0) { $0 + $1.value }
        return .degrees(Double(preceding) / Double(total) * 360)
    }

    private func endAngle(
        for index: Int,
        slices: [SessionAnalyticsToolShareSlice]) -> Angle
    {
        let total = max(1, slices.reduce(0) { $0 + $1.value })
        let current = slices.prefix(index + 1).reduce(0) { $0 + $1.value }
        return .degrees(Double(current) / Double(total) * 360)
    }

    private func legendValue(for slice: SessionAnalyticsToolShareSlice, totalCalls: Int) -> String {
        let share = totalCalls > 0 ? Double(slice.value) / Double(totalCalls) : 0
        return "\(SessionAnalyticsFormatters.percentageText(share)) • \(slice.value)"
    }
}

private enum SessionAnalyticsFormatters {
    private static let daySeconds = 24 * 60 * 60
    private static let hourSeconds = 60 * 60
    private static let millionThreshold = 1e6
    private static let thousandThreshold = 1e3

    static let fullNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    static let absoluteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func durationText(_ duration: TimeInterval) -> String {
        let rounded = Int(duration.rounded())
        if rounded >= Self.daySeconds {
            return "\(rounded / Self.daySeconds)d \(rounded % Self.daySeconds / Self.hourSeconds)h"
        }
        if rounded >= Self.hourSeconds {
            return "\(rounded / Self.hourSeconds)h \(rounded % Self.hourSeconds / 60)m"
        }
        if rounded >= 60 {
            return "\(rounded / 60)m \(rounded % 60)s"
        }
        return "\(rounded)s"
    }

    static func decimalText(_ value: Double) -> String {
        if value.rounded() == value {
            return "\(Int(value))"
        }
        return String(format: "%.1f", value)
    }

    static func percentageText(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    static func compactTokenText(_ value: Int) -> String {
        let absolute = Double(abs(value))
        let sign = value < 0 ? "-" : ""

        if absolute >= Self.millionThreshold {
            return sign + String(format: "%.1fM", absolute / Self.millionThreshold)
        }
        if absolute >= Self.thousandThreshold {
            return sign + String(format: "%.0fK", absolute / Self.thousandThreshold)
        }
        return sign + "\(value)"
    }

    static func fullTokenText(_ value: Int) -> String {
        self.fullNumberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func absoluteTimestampText(_ date: Date) -> String {
        self.absoluteDateFormatter.string(from: date)
    }

    static func shortSessionIdentifier(_ id: String) -> String {
        if id.count <= 12 {
            return id
        }
        return String(id.suffix(12))
    }

    static func topToolsText(for session: CodexSessionSummary) -> String {
        let tools = session.toolCountsByName
            .sorted {
                if $0.value != $1.value {
                    return $0.value > $1.value
                }
                return $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
            }
            .prefix(3)

        guard !tools.isEmpty else { return "No tool calls" }
        return tools.map { "\($0.key) (\($0.value))" }.joined(separator: ", ")
    }
}

extension StatusItemController {
    @discardableResult
    func addSessionAnalyticsMenuItemIfNeeded(to menu: NSMenu, provider: UsageProvider) -> Bool {
        guard provider == .codex else { return false }
        let submenu = self.makeSessionAnalyticsSubmenu()
        let width: CGFloat = 310
        let item = self.makeMenuCardItem(
            HStack(spacing: 0) {
                Text("Session Analytics")
                    .font(.system(size: NSFont.menuFont(ofSize: 0).pointSize))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 14)
                    .padding(.trailing, 28)
                    .padding(.vertical, 8)
            },
            id: "sessionAnalyticsSubmenu",
            width: width,
            submenu: submenu,
            submenuIndicatorAlignment: .trailing,
            submenuIndicatorTopPadding: 0)
        menu.addItem(item)
        return true
    }

    private func makeSessionAnalyticsSubmenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.delegate = self
        self.populateSessionAnalyticsSubmenu(submenu)
        return submenu
    }

    private func populateSessionAnalyticsSubmenu(_ submenu: NSMenu) {
        self.store.requestCodexSessionAnalyticsRefreshIfStale(reason: "session analytics submenu")
        submenu.removeAllItems()

        let snapshot = self.store.codexSessionAnalyticsSnapshot()
        let error = self.store.lastCodexSessionAnalyticsError()

        if !Self.menuCardRenderingEnabled {
            let item = NSMenuItem()
            item.isEnabled = false
            item.representedObject = snapshot == nil ? "sessionAnalyticsEmptyState" : "sessionAnalyticsContent"
            submenu.addItem(item)
            return
        }

        let width: CGFloat = 310

        guard let snapshot else {
            submenu.addItem(self.makeSessionAnalyticsHostedItem(
                SessionAnalyticsEmptyStateView(error: error, width: width),
                id: "sessionAnalyticsEmptyState",
                width: width))
            return
        }

        submenu.addItem(self.makeSessionAnalyticsHostedItem(
            SessionAnalyticsWindowSelectorView(
                selectedWindow: self.settings.codexSessionAnalyticsWindowSize,
                width: width)
            { [weak submenu] value in
                guard value != self.settings.codexSessionAnalyticsWindowSize else { return }
                self.settings.codexSessionAnalyticsWindowSize = value
                self.store.refreshCodexSessionAnalyticsIfNeeded(force: true)
                DispatchQueue.main.async {
                    guard let submenu else { return }
                    self.populateSessionAnalyticsSubmenu(submenu)
                }
            },
            id: "sessionAnalyticsContent",
            width: width))

        submenu.addItem(.separator())
        submenu.addItem(self.makeSessionAnalyticsSectionHeaderItem("Summary"))
        for focus in SessionAnalyticsSummaryFocus.allCases {
            submenu.addItem(self.makeSessionAnalyticsSummaryItem(
                focus: focus,
                snapshot: snapshot,
                width: width))
        }

        submenu.addItem(.separator())
        submenu.addItem(self.makeSessionAnalyticsSectionHeaderItem("Top Tools"))
        if snapshot.topTools.isEmpty {
            submenu.addItem(self.makeSessionAnalyticsNoteItem("No tool calls found."))
        } else {
            submenu.addItem(self.makeSessionAnalyticsHostedItem(
                SessionAnalyticsToolShareChartView(snapshot: snapshot, width: width),
                id: "sessionAnalyticsToolChart",
                width: width))
            for (index, tool) in snapshot.topTools.enumerated() {
                submenu.addItem(self.makeSessionAnalyticsToolItem(
                    tool: tool,
                    snapshot: snapshot,
                    width: width,
                    index: index))
            }
        }

        submenu.addItem(.separator())
        submenu.addItem(self.makeSessionAnalyticsSectionHeaderItem("Recent Sessions"))
        if snapshot.recentSessions.isEmpty {
            submenu.addItem(self.makeSessionAnalyticsNoteItem("No recent sessions found."))
        } else {
            for session in snapshot.recentSessions {
                submenu.addItem(self.makeSessionAnalyticsSessionItem(session: session, width: width))
            }
        }
    }

    private func makeSessionAnalyticsSummaryItem(
        focus: SessionAnalyticsSummaryFocus,
        snapshot: CodexSessionAnalyticsSnapshot,
        width: CGFloat) -> NSMenuItem
    {
        self.makeMenuCardItem(
            SessionAnalyticsMetricRowView(
                title: focus.title,
                value: focus.value(in: snapshot)),
            id: "sessionAnalyticsSummary.\(focus.rawValue)",
            width: width,
            submenu: self.makeSessionAnalyticsSummaryDetailSubmenu(focus: focus, snapshot: snapshot),
            showsSubmenuIndicator: false,
            submenuIndicatorAlignment: .trailing,
            submenuIndicatorTopPadding: 0)
    }

    private func makeSessionAnalyticsToolItem(
        tool: CodexToolAggregate,
        snapshot: CodexSessionAnalyticsSnapshot,
        width: CGFloat,
        index: Int) -> NSMenuItem
    {
        self.makeMenuCardItem(
            SessionAnalyticsToolRowView(
                tool: tool,
                sessionsAnalyzed: snapshot.sessionsAnalyzed),
            id: "sessionAnalyticsTool.\(index)",
            width: width,
            submenu: self.makeSessionAnalyticsToolDetailSubmenu(tool: tool, snapshot: snapshot),
            showsSubmenuIndicator: false,
            submenuIndicatorAlignment: .trailing,
            submenuIndicatorTopPadding: 0)
    }

    private func makeSessionAnalyticsSessionItem(
        session: CodexSessionSummary,
        width: CGFloat) -> NSMenuItem
    {
        self.makeMenuCardItem(
            SessionAnalyticsSessionRowView(session: session),
            id: "sessionAnalyticsSession.\(session.id)",
            width: width,
            submenu: self.makeSessionAnalyticsSessionDetailSubmenu(session: session),
            showsSubmenuIndicator: false,
            submenuIndicatorAlignment: .trailing,
            submenuIndicatorTopPadding: 0)
    }

    private func makeSessionAnalyticsSummaryDetailSubmenu(
        focus: SessionAnalyticsSummaryFocus,
        snapshot: CodexSessionAnalyticsSnapshot) -> NSMenu
    {
        let diagnostics = snapshot.summaryDiagnostics
        let durationSpread = [
            SessionAnalyticsFormatters.durationText(diagnostics.durationP25Seconds),
            SessionAnalyticsFormatters.durationText(diagnostics.durationP50Seconds),
            SessionAnalyticsFormatters.durationText(diagnostics.durationP75Seconds),
        ].joined(separator: " / ")
        let toolCallSpread = [
            SessionAnalyticsFormatters.decimalText(diagnostics.avgToolCalls),
            SessionAnalyticsFormatters.decimalText(snapshot.medianToolCallsPerSession),
            SessionAnalyticsFormatters.decimalText(diagnostics.toolCallsP75),
        ].joined(separator: " / ")
        let topFailingTool = diagnostics.topFailingToolName.map {
            "\($0) • \(diagnostics.topFailingToolFailures)"
        } ?? "No failures"

        let lines: [(String, String)] = switch focus {
        case .sessionsAnalyzed:
            [
                ("Window span", SessionAnalyticsFormatters.durationText(diagnostics.windowSpanSeconds)),
                ("Token coverage", "\(diagnostics.sessionsWithTokens)/\(snapshot.sessionsAnalyzed) sessions"),
                ("Failure coverage", "\(diagnostics.sessionsWithFailures)/\(snapshot.sessionsAnalyzed) sessions"),
                ("Check coverage", "\(diagnostics.sessionsWithChecks)/\(snapshot.sessionsAnalyzed) sessions"),
            ]
        case .medianDuration:
            [
                ("p25 / p50 / p75", durationSpread),
                ("Longest session", SessionAnalyticsFormatters.durationText(diagnostics.longestSessionDurationSeconds)),
                ("Top 3 share", SessionAnalyticsFormatters.percentageText(diagnostics.top3DurationShare)),
            ]
        case .medianToolCalls:
            [
                ("avg / median / p75", toolCallSpread),
                (">50 calls", "\(diagnostics.sessionsOver50Calls) sessions"),
                (">100 calls", "\(diagnostics.sessionsOver100Calls) sessions"),
                ("Peak session calls", "\(diagnostics.maxToolCallsInSingleSession)"),
            ]
        case .toolFailureRate:
            [
                ("Failed / total calls", "\(diagnostics.failedCalls) / \(diagnostics.totalCalls)"),
                ("Failed sessions", "\(diagnostics.sessionsWithFailures)/\(snapshot.sessionsAnalyzed) sessions"),
                ("Top failing tool", topFailingTool),
            ]
        }

        return self.makeSessionAnalyticsDetailSubmenu(
            title: focus.title,
            subtitle: "Window diagnostics",
            lines: lines,
            id: "sessionAnalyticsContent")
    }

    private func makeSessionAnalyticsToolDetailSubmenu(
        tool: CodexToolAggregate,
        snapshot: CodexSessionAnalyticsSnapshot) -> NSMenu
    {
        let maxCallsText = tool.maxCallsSessionTitle.map {
            "\(tool.maxCallsInSingleSession) • \($0)"
        } ?? "\(tool.maxCallsInSingleSession)"
        let failureText =
            "\(tool.failureCount) • \(SessionAnalyticsFormatters.percentageText(tool.failureRate)) rate"

        return self.makeSessionAnalyticsDetailSubmenu(
            title: tool.name,
            subtitle: "Recent window behavior",
            lines: [
                ("Used in", "\(tool.sessionCountUsingTool)/\(snapshot.sessionsAnalyzed) sessions"),
                ("Share of calls", SessionAnalyticsFormatters.percentageText(tool.callShare)),
                ("Avg active-session calls", SessionAnalyticsFormatters.decimalText(tool.averageCallsPerActiveSession)),
                ("Max in one session", maxCallsText),
                ("Failures", failureText),
                ("Long-running calls", "\(tool.longRunningCount)"),
            ],
            id: "sessionAnalyticsContent")
    }

    private func makeSessionAnalyticsSessionDetailSubmenu(session: CodexSessionSummary) -> NSMenu {
        let statsText = [
            SessionAnalyticsFormatters.durationText(session.durationSeconds),
            "\(session.toolCallCount) calls",
            "\(session.toolFailureCount) failures",
            "\(session.longRunningCallCount) long-running",
            "\(session.verificationAttemptCount) checks",
        ].joined(separator: "  •  ")
        let tokenLines: [(String, String)]
        if let tokenUsage = session.tokenUsage {
            let inputCached =
                "\(SessionAnalyticsFormatters.fullTokenText(tokenUsage.inputTokens)) / " +
                "\(SessionAnalyticsFormatters.fullTokenText(tokenUsage.cachedInputTokens))"
            let outputReasoning =
                "\(SessionAnalyticsFormatters.fullTokenText(tokenUsage.outputTokens)) / " +
                "\(SessionAnalyticsFormatters.fullTokenText(tokenUsage.reasoningOutputTokens))"
            tokenLines = [
                ("Total tokens", "\(SessionAnalyticsFormatters.fullTokenText(tokenUsage.totalTokens)) tok"),
                ("Input / Cached", inputCached),
                ("Output / Reasoning", outputReasoning),
            ]
        } else {
            tokenLines = [("Total tokens", "No token data")]
        }

        return self.makeSessionAnalyticsDetailSubmenu(
            title: session.title,
            subtitle: SessionAnalyticsFormatters.absoluteTimestampText(session.startedAt),
            lines: [
                ("Session ID", SessionAnalyticsFormatters.shortSessionIdentifier(session.id)),
                ("Stats", statsText),
            ] + tokenLines + [
                ("Top tools", SessionAnalyticsFormatters.topToolsText(for: session)),
            ],
            id: "sessionAnalyticsContent")
    }

    private func makeSessionAnalyticsDetailSubmenu(
        title: String,
        subtitle: String?,
        lines: [(String, String)],
        id: String) -> NSMenu
    {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.delegate = self

        if !Self.menuCardRenderingEnabled {
            let item = NSMenuItem()
            item.isEnabled = false
            item.representedObject = id
            submenu.addItem(item)
            return submenu
        }

        let width: CGFloat = 310
        submenu.addItem(self.makeSessionAnalyticsHostedItem(
            SessionAnalyticsDetailPanel(
                title: title,
                subtitle: subtitle,
                lines: lines,
                width: width),
            id: id,
            width: width))
        return submenu
    }

    private func makeSessionAnalyticsHostedItem(
        _ view: some View,
        id: String,
        width: CGFloat) -> NSMenuItem
    {
        let hosting = SessionAnalyticsMenuHostingView(rootView: view)
        let controller = NSHostingController(rootView: view)
        let size = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: size.height))

        let item = NSMenuItem()
        item.view = hosting
        item.isEnabled = false
        item.representedObject = id
        return item
    }

    private func makeSessionAnalyticsSectionHeaderItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func makeSessionAnalyticsNoteItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
