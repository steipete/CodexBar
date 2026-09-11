import CodexBarCore
import Foundation
import SwiftUI

struct RemoteCodexCostPresentation {
    let title: String
    let lines: [String]

    init(report: CodexHostCostReport, index: Int, hidePersonalInfo: Bool, now: Date = Date()) {
        self.title = hidePersonalInfo ? L("Host %d", index + 1) : report.host
        guard let summary = report.summary else {
            self.lines = [report.error.map { L($0) } ?? L("Refreshing…")]
            return
        }
        func amount(_ cost: Double?, _ tokens: Int?) -> String {
            let costText = cost.map(UsageFormatter.usdString) ?? "—"
            let tokenText = tokens.map(UsageFormatter.tokenCountString) ?? "—"
            return "\(costText) · \(L("%@ tokens", tokenText))"
        }
        self.lines = [
            "\(L("Today")): \(amount(summary.sessionCostUSD, summary.sessionTokens))",
            "\(L("Last %d days", summary.historyDays)): " +
                amount(summary.last30DaysCostUSD, summary.last30DaysTokens),
            L("Day boundaries: %@", summary.bucketTimeZone),
            UsageFormatter.updatedString(from: summary.updatedAt, now: now),
        ] + (summary.historyCoverageIsEstablished ? [] : [L("Partial history; scan is incomplete.")]) +
            (summary.coverage.unpriced > 0 ? [L("Some usage has no known price.")] : [])
    }
}

@MainActor
struct RemoteCodexCostView: View {
    @Bindable var costs: RemoteCodexCostStore
    let hidePersonalInfo: Bool

    var body: some View {
        if !self.costs.reports.isEmpty || self.costs.configurationError != nil {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("Remote Codex estimates")).font(.headline)
                    if self.costs.isRefreshing { ProgressView().controlSize(.small) }
                }
                Text(L("API-equivalent estimates by host. These reports are excluded from local totals."))
                    .font(.caption).foregroundStyle(.secondary)
                if let error = self.costs.configurationError {
                    Text(L(error)).font(.callout)
                }
                ForEach(Array(self.costs.reports.enumerated()), id: \.element.id) { index, report in
                    let model = RemoteCodexCostPresentation(
                        report: report, index: index, hidePersonalInfo: self.hidePersonalInfo)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.title).font(.subheadline.weight(.semibold))
                        ForEach(model.lines, id: \.self) { line in
                            Text(line).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
struct RemoteCodexCostHostsEditor: View {
    @Bindable var settings: SettingsStore
    @State private var hosts = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(L("Remote Codex costs")) {
                TextField(L("SSH hosts"), text: self.$hosts, prompt: Text("user@host, user@host"))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180)
                    .onSubmit(self.apply)
                Button(L("Apply"), action: self.apply)
                    .disabled(self.hosts == self.settings.codexRemoteCostHosts)
            }
            Text(L("Optional. Reads cost summaries over SSH; remote hosts need an updated CodexBar CLI. " +
                    "Reports stay separate. Clear the field to disconnect."))
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(L(error)).font(.caption).foregroundStyle(.red) }
        }
        .onAppear { self.hosts = self.settings.codexRemoteCostHosts }
        .onChange(of: self.settings.codexRemoteCostHosts) { _, value in self.hosts = value }
    }

    private func apply() {
        do {
            let hosts = try RemoteCodexCostFetcher.hosts(from: self.hosts)
            self.settings.codexRemoteCostHosts = hosts.joined(separator: ", ")
            self.hosts = self.settings.codexRemoteCostHosts
            self.error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
