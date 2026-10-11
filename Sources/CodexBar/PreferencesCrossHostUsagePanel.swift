import CodexBarCore
import SwiftUI

/// A manual, in-memory report kept separate from the account-scoped local spend dashboard.
@MainActor
struct CrossHostUsagePanel: View {
    let calendar: Calendar
    @State private var provider: UsageProvider = .codex
    @State private var host = ""
    @State private var report: CombinedUsageLedgerReport?
    @State private var errorMessage: String?
    @State private var requestID: UUID?
    @State private var operation: Task<Void, Never>?

    var body: some View {
        SpendDashboardPanel {
            VStack(alignment: .leading, spacing: 12) {
                Label(L("Cross-host usage — Experimental"), systemImage: "desktopcomputer")
                    .font(.headline)
                Text(L("Native histories on this Mac and one SSH host. Runs only when requested; "
                        + "conversation text stays on each machine."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                self.controls
                if self.operation != nil {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(L("Reading usage histories…"))
                            .font(.caption)
                        Spacer()
                        Button(L("Cancel")) { self.cancel() }
                    }
                }
                if let errorMessage = self.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let report = self.report {
                    self.results(report)
                }
            }
        }
        .accessibilityIdentifier("cross-host-usage-panel")
        .onDisappear { self.cancel() }
        .onChange(of: self.provider) { _, _ in self.reset() }
        .onChange(of: self.host) { _, _ in self.reset() }
        .onChange(of: self.calendar.timeZone.identifier) { _, _ in self.reset() }
    }

    private var controls: some View {
        HStack {
            Picker(L("Provider"), selection: self.$provider) {
                Text(verbatim: "Codex").tag(UsageProvider.codex)
                Text(verbatim: "Claude Code").tag(UsageProvider.claude)
            }
            .frame(maxWidth: 180)
            .disabled(self.operation != nil)
            TextField(L("SSH host alias"), text: self.$host)
                .textFieldStyle(.roundedBorder)
                .disabled(self.operation != nil)
                .accessibilityIdentifier("cross-host-usage-host")
            Button(L("Fetch report")) { self.fetch() }
                .disabled(self.operation != nil || self.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("cross-host-usage-fetch")
        }
    }

    private func results(_ report: CombinedUsageLedgerReport) -> some View {
        let combined = report.combined
        return VStack(alignment: .leading, spacing: 8) {
            Divider()
            if report.reports.contains(where: { $0.ledger != nil }) {
                Text(combined.coverageIsEstablished
                    ? L("Last 30 days — deduplicated") : L("Last 30 days — recorded subtotal"))
                    .font(.subheadline.weight(.medium))
                Text(spendDashboardMetricText(
                    cost: combined.costUSD,
                    tokens: combined.totalTokens,
                    currencyCode: "USD"))
                    .font(.title3.monospacedDigit())
                Text(L("Recorded cost or API-price estimate — not a billing receipt."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(L("Usage history unavailable"))
                    .font(.subheadline.weight(.medium))
            }
            Text(L("Duplicates removed: %d · Conflicts excluded: %d", combined.duplicateCount, combined.conflictCount))
                .font(.caption)
            Text(L(
                "Unidentified records excluded: %d · Legacy identities: %d",
                combined.unidentifiedCount,
                combined.legacyIdentityCount))
                .font(.caption)
            if !combined.coverageIsEstablished {
                Text(L("Coverage is incomplete. Missing histories or uncertain records "
                        + "can leave usage out of this subtotal."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if combined.legacyIdentityCount > 0 {
                Text(L("Legacy record identities cannot establish that all cross-host overlaps were removed."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if combined.unpricedCount > 0 {
                Text(L("Missing or conflicting prices: %d", combined.unpricedCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(report.reports.enumerated()), id: \.offset) { _, source in
                VStack(alignment: .leading, spacing: 2) {
                    if let ledger = source.ledger {
                        Text("\(source.host) · \(ledger.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        if ledger.incompleteRequestCount > 0 {
                            Text(L("Incomplete requests excluded: %d", ledger.incompleteRequestCount))
                        }
                        if !ledger.warnings.isEmpty {
                            DisclosureGroup(L("Source diagnostics")) {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(ledger.warnings.enumerated()), id: \.offset) { _, warning in
                                        Text(verbatim: warning)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.top, 4)
                            }
                        }
                    } else {
                        Text("\(source.host) · \(source.error ?? L("Usage history unavailable"))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        }
    }

    /// Invalidate the generation before cancelling so a late SSH completion cannot publish stale totals.
    private func cancel() {
        self.requestID = nil
        self.operation?.cancel()
        self.operation = nil
    }

    private func reset() {
        self.cancel()
        self.report = nil
        self.errorMessage = nil
    }

    private func fetch() {
        self.reset()
        let requestID = UUID()
        let provider = self.provider
        let host = self.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar = self.calendar
        self.requestID = requestID
        self.operation = Task {
            do {
                let report = try await UsageLedgerCollector.collect(
                    provider: provider, host: host, historyDays: 30, calendar: calendar)
                guard !Task.isCancelled, self.requestID == requestID else { return }
                self.report = report
            } catch is CancellationError {
                // Cancelling is an explicit user action; retain no failure message.
            } catch {
                guard !Task.isCancelled, self.requestID == requestID else { return }
                self.errorMessage = error.localizedDescription
            }
            guard self.requestID == requestID else { return }
            self.requestID = nil
            self.operation = nil
        }
    }
}
