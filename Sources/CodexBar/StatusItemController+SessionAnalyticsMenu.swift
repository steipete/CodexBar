import AppKit
import CodexBarCore
import SwiftUI

private final class SessionAnalyticsMenuHostingView<Content: View>: NSHostingView<Content> {
    override var allowsVibrancy: Bool {
        true
    }
}

private struct SessionAnalyticsMetricCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(self.value)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color(nsColor: .labelColor))
            Text(self.title)
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
    }
}

private struct SessionAnalyticsToolRow: View {
    let tool: CodexToolAggregate
    let maximumCount: Int

    private var fillFraction: CGFloat {
        guard self.maximumCount > 0 else { return 0 }
        return CGFloat(self.tool.callCount) / CGFloat(self.maximumCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(self.tool.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(self.tool.callCount)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color(nsColor: .separatorColor).opacity(0.35))
                    Capsule(style: .continuous)
                        .fill(Color(red: 73 / 255, green: 163 / 255, blue: 176 / 255))
                        .frame(width: max(8, geometry.size.width * self.fillFraction))
                }
            }
            .frame(height: 6)
        }
    }
}

private struct SessionAnalyticsSessionRow: View {
    let session: CodexSessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(self.session.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(self.session.startedAt.relativeDescription())
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(1)
            }

            Text(self.statsText)
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var statsText: String {
        [
            Self.durationText(self.session.durationSeconds),
            "\(self.session.toolCallCount) calls",
            "\(self.session.toolFailureCount) failures",
            "\(self.session.verificationAttemptCount) checks",
        ].joined(separator: "  •  ")
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let rounded = Int(duration.rounded())
        if rounded >= 3600 {
            return "\(rounded / 3600)h \(rounded % 3600 / 60)m"
        }
        if rounded >= 60 {
            return "\(rounded / 60)m \(rounded % 60)s"
        }
        return "\(rounded)s"
    }
}

private struct SessionAnalyticsMenuView: View {
    let snapshot: CodexSessionAnalyticsSnapshot?
    let error: String?
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let snapshot {
                self.summarySection(snapshot)
                Divider()
                self.topToolsSection(snapshot)
                Divider()
                self.recentSessionsSection(snapshot)
            } else {
                Text("No local Codex session data found.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let error, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: self.width, alignment: .leading)
    }

    private func summarySection(_ snapshot: CodexSessionAnalyticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Summary")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10),
            ], spacing: 10) {
                SessionAnalyticsMetricCard(
                    title: "Sessions analyzed",
                    value: "\(snapshot.sessionsAnalyzed)")
                SessionAnalyticsMetricCard(
                    title: "Median duration",
                    value: Self.durationText(snapshot.medianSessionDurationSeconds))
                SessionAnalyticsMetricCard(
                    title: "Median tool calls",
                    value: Self.callsText(snapshot.medianToolCallsPerSession))
                SessionAnalyticsMetricCard(
                    title: "Tool failure rate",
                    value: Self.failureRateText(snapshot.toolFailureRate))
            }
        }
    }

    private func topToolsSection(_ snapshot: CodexSessionAnalyticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top Tools")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))

            if snapshot.topTools.isEmpty {
                Text("No tool calls found.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            } else {
                let maximum = snapshot.topTools.map(\.callCount).max() ?? 0
                ForEach(Array(snapshot.topTools.enumerated()), id: \.offset) { _, tool in
                    SessionAnalyticsToolRow(tool: tool, maximumCount: maximum)
                }
            }
        }
    }

    private func recentSessionsSection(_ snapshot: CodexSessionAnalyticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Sessions")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))

            ForEach(Array(snapshot.recentSessions.enumerated()), id: \.element.id) { index, session in
                if index > 0 {
                    Divider()
                }
                SessionAnalyticsSessionRow(session: session)
            }
        }
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let rounded = Int(duration.rounded())
        if rounded >= 3600 {
            return "\(rounded / 3600)h \(rounded % 3600 / 60)m"
        }
        if rounded >= 60 {
            return "\(rounded / 60)m \(rounded % 60)s"
        }
        return "\(rounded)s"
    }

    private static func callsText(_ value: Double) -> String {
        if value.rounded() == value {
            return "\(Int(value))"
        }
        return String(format: "%.1f", value)
    }

    private static func failureRateText(_ rate: Double) -> String {
        String(format: "%.0f%%", rate * 100)
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
        self.store.requestCodexSessionAnalyticsRefreshIfStale(reason: "session analytics submenu")

        let width: CGFloat = 310
        let submenu = NSMenu()
        submenu.delegate = self

        let snapshot = self.store.codexSessionAnalyticsSnapshot()
        let error = self.store.lastCodexSessionAnalyticsError()

        if !Self.menuCardRenderingEnabled {
            let item = NSMenuItem()
            item.isEnabled = false
            item.representedObject = snapshot == nil ? "sessionAnalyticsEmptyState" : "sessionAnalyticsContent"
            submenu.addItem(item)
            return submenu
        }

        let analyticsView = SessionAnalyticsMenuView(snapshot: snapshot, error: error, width: width)
        let hosting = SessionAnalyticsMenuHostingView(rootView: analyticsView)
        let controller = NSHostingController(rootView: analyticsView)
        let size = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: size.height))

        let item = NSMenuItem()
        item.view = hosting
        item.isEnabled = false
        item.representedObject = snapshot == nil ? "sessionAnalyticsEmptyState" : "sessionAnalyticsContent"
        submenu.addItem(item)
        return submenu
    }
}
