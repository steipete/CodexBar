import CodexBarCore
import Foundation
import SwiftUI

struct RemoteCostPresentation {
    let title: String
    let lines: [String]

    init(report: RemoteHostCostReport, index: Int, hidePersonalInfo: Bool, now: Date = Date()) {
        let host = hidePersonalInfo ? L("Host %d", index + 1) : report.host
        self.title = "\(host) — \(Self.providerName(report.provider))"
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
            (summary.coverage.unpriced > 0 ? [L("Some usage has no known price.")] : []) +
            [Self.disclaimer(report.provider)]
    }

    static func providerName(_ rawValue: String) -> String {
        guard let provider = UsageProvider(rawValue: rawValue) else { return rawValue.capitalized }
        return ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
    }

    static func disclaimer(_ provider: String) -> String {
        // Provider-specific by design: Claude subscription estimates require different billing semantics.
        provider == UsageProvider.claude.rawValue
            ? L("Notional API-rate estimate; subscription charges are not measured.")
            : L("API-equivalent estimate; not a subscription bill.")
    }

    static func hostIndex(of report: RemoteHostCostReport, in reports: [RemoteHostCostReport]) -> Int {
        var hosts: [String] = []
        for candidate in reports where !hosts.contains(candidate.host) {
            hosts.append(candidate.host)
        }
        return hosts.firstIndex(of: report.host) ?? 0
    }
}

@MainActor
struct RemoteCostView: View {
    @Bindable var costs: RemoteCostStore
    let hidePersonalInfo: Bool

    var body: some View {
        if !self.costs.reports.isEmpty || self.costs.configurationError != nil {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("Remote Claude and Codex estimates")).font(.headline)
                    if self.costs.isRefreshing { ProgressView().controlSize(.small) }
                }
                Text(L("Per-host estimates stay separate from local totals and from each other."))
                    .font(.caption).foregroundStyle(.secondary)
                if let error = self.costs.configurationError {
                    Text(L(error)).font(.callout)
                }
                ForEach(self.costs.reports) { report in
                    let model = RemoteCostPresentation(
                        report: report,
                        index: RemoteCostPresentation.hostIndex(of: report, in: self.costs.reports),
                        hidePersonalInfo: self.hidePersonalInfo)
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
struct RemoteCostHostsEditor: View {
    @Bindable var settings: SettingsStore
    @State private var hosts = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: self.$settings.remoteCostsEnabled) {
                Text(L("Fetch costs from SSH devices"))
            }
            LabeledContent(L("Remote costs over SSH")) {
                TextField(L("SSH hosts"), text: self.$hosts, prompt: Text("ubuntu, user@host"))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180)
                    .onSubmit(self.apply)
                Button(L("Apply"), action: self.apply)
                    .disabled(self.hosts == self.settings.remoteCostHosts)
            }
            .disabled(!self.settings.remoteCostsEnabled)
            Text(L("Reads Claude and Codex summaries over SSH using your existing SSH configuration. " +
                    "Remote hosts need an updated CodexBar CLI. Disable the toggle to stop connecting."))
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(L(error)).font(.caption).foregroundStyle(.red) }
        }
        .onAppear { self.hosts = self.settings.remoteCostHosts }
        .onChange(of: self.settings.remoteCostHosts) { _, value in self.hosts = value }
    }

    private func apply() {
        do {
            let hosts = try RemoteCostFetcher.hosts(from: self.hosts)
            self.settings.remoteCostHosts = hosts.joined(separator: ", ")
            self.hosts = self.settings.remoteCostHosts
            self.error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
