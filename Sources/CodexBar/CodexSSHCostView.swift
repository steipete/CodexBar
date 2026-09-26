import CodexBarCore
import SwiftUI

struct CodexSSHCostSettingsView: View {
    let query: CodexSSHCostQuery
    let settings: SettingsStore

    var body: some View {
        CodexSSHCostView(
            query: self.query,
            calendar: self.settings.costUsageBucketCalendar,
            hidePersonalInfo: self.settings.hidePersonalInfo)
    }
}

struct CodexSSHCostView: View {
    let query: CodexSSHCostQuery
    let calendar: Calendar
    let hidePersonalInfo: Bool

    private var hostBinding: Binding<String> {
        Binding(get: { self.query.host }, set: { self.query.setHost($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L("SSH host"))
                Group {
                    if self.hidePersonalInfo {
                        SecureField(L("SSH host"), text: self.hostBinding)
                    } else {
                        TextField(L("SSH host"), text: self.hostBinding, prompt: Text("research-server"))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .disabled(self.query.isRunning)
                .accessibilityIdentifier("ssh-cost-host")

                Button(self.query.isRunning ? L("Cancel") : L("Refresh")) {
                    if self.query.isRunning {
                        self.query.cancel()
                    } else {
                        self.query.refresh(calendar: self.calendar)
                    }
                }
                .disabled(self.query.isCancelling || (!self.query.isRunning && !self.query.canRefresh))
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("ssh-cost-refresh")
            }
            Text(L("Uses native Codex history. The SSH host needs a CodexBar CLI supporting --daily-summary."))
                .font(.caption)
                .foregroundStyle(.secondary)

            GeometryReader { geometry in
                ScrollView {
                    HStack(alignment: .top, spacing: 16) {
                        self.reportCard(title: L("This Mac"), source: "local", width: (geometry.size.width - 16) / 2)
                        self.reportCard(
                            title: Self.hostTitle(self.query.host, hidden: self.hidePersonalInfo),
                            source: "ssh",
                            width: (geometry.size.width - 16) / 2)
                    }
                }
            }
            HStack {
                if self.query.isRunning { ProgressView().controlSize(.small) }
                if self.query.isCancelling {
                    Text(L("Cancelling…"))
                } else if let message = self.query.message {
                    Text(L(message))
                }
            }
            .font(.caption)
            Text(L("API-equivalent estimates · USD · Host totals are separate."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .onExitCommand { self.query.cancel() }
    }

    private func reportCard(title: String, source: String, width: CGFloat) -> some View {
        let report = self.query.reports.first { $0.source == source }
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let history = report?.history {
                    let summary = history.summary
                    self.windowLine(L("Today"), summary.today)
                    self.windowLine(L("Last 30 days"), summary.history)
                    CostHistoryChartMenuView(
                        provider: .codex,
                        daily: history.snapshot.daily,
                        totalCostUSD: history.snapshot.last30DaysCostUSD,
                        costLabelFormatter: { Self.amountText($0) },
                        historyCoverageIsEstablished: history.snapshot.historyCoverageIsEstablished,
                        historyIsRefreshing: false,
                        calendar: history.calendar,
                        dateRange: history.dateRange,
                        hidePersonalInfo: self.hidePersonalInfo,
                        width: max(0, width - 32))
                        .accessibilityIdentifier("ssh-cost-chart-\(source)")
                    Text(L("Snapshot updated: %@", summary.updatedAt.ISO8601Format()))
                        .monospacedDigit()
                    Text(L("Day boundaries: %@", summary.bucketTimeZone))
                    ForEach(Self.coverageHints(history), id: \.self) { hint in
                        Text(hint).foregroundStyle(.secondary)
                    }
                } else if let error = report?.error {
                    Text(L(error)).foregroundStyle(.secondary)
                } else if self.query.isCancelling || self.query.message == "Cancelled" {
                    Text(L("Cancelled")).foregroundStyle(.secondary)
                } else {
                    Text(self.query.isRunning ? L("Waiting for summary…") : L("No summary loaded."))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Text(title).lineLimit(1).truncationMode(.middle)
        }
        .frame(width: width, alignment: .topLeading)
    }

    private func windowLine(_ label: String, _ window: CodexHostCostWindow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.subheadline).bold()
            Text(L(
                "%@ · %@ tokens",
                Self.amountText(window.costUSD),
                window.totalTokens.map(UsageFormatter.tokenCountString) ?? L("Unknown")))
                .monospacedDigit()
        }
    }

    static func amountText(_ amount: Double?) -> String {
        guard let amount else { return L("Unknown") }
        return amount > 0 && amount < 0.01 ? "<" + UsageFormatter.usdString(0.01) : UsageFormatter.usdString(amount)
    }

    static func hostTitle(_ host: String, hidden: Bool) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return hidden || trimmed.isEmpty ? L("SSH host") : trimmed
    }

    static func coverageHints(_ history: CodexSSHCostReport.History) -> [String] {
        let summary = history.summary
        var hints: [String] = []
        if !summary.historyCoverageIsEstablished || history.dailySummary.historyScanIsPartial {
            hints.append(L("Partial history; scan is incomplete."))
        }
        if [summary.today, summary.history].contains(where: { $0.coverage.unpriced > 0 || $0.coverage.unmetered > 0 }) {
            hints.append(L("Some usage has no known price."))
        }
        if summary.today.incompleteRequestCount > 0 {
            hints.append(L("Today: %d incomplete requests excluded.", summary.today.incompleteRequestCount))
        }
        if summary.history.incompleteRequestCount > 0 {
            hints.append(L("Last 30 days: %d incomplete requests excluded.", summary.history.incompleteRequestCount))
        }
        return hints
    }
}
