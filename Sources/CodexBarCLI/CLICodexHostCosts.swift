import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    static func runCodexHostCosts(
        _ values: ParsedValues,
        providers: [UsageProvider],
        unsupported: [UsageProvider],
        historyDays days: Int,
        output: CLIOutputPreferences) async
    {
        let remote = values.options["remote"]?.last
        let summaryOnly = values.flags.contains("summaryOnly")
        // Provider-specific by design: this versioned transport contains only native Codex history.
        guard providers == [.codex], unsupported.isEmpty,
              (values.options["remote"]?.count ?? 0) <= 1,
              values.options["groupBy"] == nil, !values.flags.contains("breakdown"),
              !(remote != nil && summaryOnly), !summaryOnly || output.format == .json
        else {
            Self.exit(
                code: .failure,
                message: "Use --provider codex and one --remote host. --summary-only requires JSON; " +
                    "neither mode accepts --group-by or --breakdown, and the modes cannot be combined.",
                output: output,
                kind: .args)
        }
        if let remote {
            do { try RemoteCodexCostFetcher.validateHost(remote) } catch {
                Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .args)
            }
        }
        let force = values.flags.contains("refresh")
        let calendar = CostUsageBucketTimeZone.calendar(
            identifier: Self.stringFromAppDefaults("tokenCostUsageBucketTimeZone"))
        let cancellation = CodexHostCostCancellation()
        let monitor = CLITerminationSignalMonitor { signal in cancellation.request(signal: signal) }
        let operation = Task {
            try await Self.collectCodexHostCosts(
                remote: remote,
                historyDays: days,
                local: {
                    // Provider-specific by design: each host scans native Codex history exactly once.
                    let snapshot = try await CostUsageFetcher(calendar: calendar).loadTokenSnapshot(
                        provider: .codex,
                        forceRefresh: force,
                        historyDays: days,
                        refreshPricingInBackground: false,
                        includePiSessions: false)
                    return CodexCostSummary(snapshot: snapshot, calendar: calendar)
                },
                fetchRemote: { host in
                    try await RemoteCodexCostFetcher().fetch(host: host, historyDays: days, force: force)
                })
        }
        cancellation.bind { operation.cancel() }
        let result = await operation.result
        monitor.cancel()
        if let signal = cancellation.signal {
            CLITerminationSignalMonitor.terminateActiveHelpersAndReraise(signal)
            return
        }
        let reports: [CodexHostCostReport]
        do {
            reports = try result.get()
        } catch {
            Self.exit(code: .failure, message: "Cost report cancelled.", output: output, kind: .runtime)
        }
        if output.format == .json {
            if summaryOnly {
                Self.printJSON(reports.compactMap(\.summary), pretty: output.pretty)
            } else {
                Self.printJSON(reports, pretty: output.pretty)
            }
        } else {
            print(reports.map(Self.renderHostCostText).joined(separator: "\n\n"))
            print("\nHost reports are separate; overlapping histories are not added together.")
        }
        let failed = reports.contains { $0.error != nil }
        Self.exit(code: failed ? .failure : .success, output: output, kind: failed ? .provider : .runtime)
    }

    static func collectCodexHostCosts(
        remote: String?,
        historyDays: Int,
        local: @Sendable () async throws -> CodexCostSummary,
        fetchRemote: @Sendable (String) async throws -> CodexCostSummary) async throws -> [CodexHostCostReport]
    {
        try Task.checkCancellation()
        var reports: [CodexHostCostReport] = []
        do {
            let summary = try await local()
            try summary.validate(historyDays: historyDays)
            reports.append(.init(host: "local", source: "local", summary: summary))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            reports.append(.init(
                host: "local", source: "local", summary: nil, error: "Local Codex cost history is unavailable."))
        }
        try Task.checkCancellation()
        if let remote {
            do {
                let summary = try await fetchRemote(remote)
                try summary.validate(historyDays: historyDays)
                reports.append(.init(host: remote, source: "ssh", summary: summary))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                let message = (error as? RemoteCodexCostError)?.localizedDescription
                    ?? RemoteCodexCostError.unavailable.localizedDescription
                reports.append(.init(host: remote, source: "ssh", summary: nil, error: message))
            }
        }
        try Task.checkCancellation()
        return reports
    }

    static func renderHostCostText(_ report: CodexHostCostReport) -> String {
        let title = report.source == "local" ? "This machine" : report.host
        guard let summary = report.summary else {
            return "\(title): \(report.error ?? "Cost history unavailable")"
        }
        func line(_ label: String, _ window: CodexHostCostWindow) -> String {
            let cost = window.costUSD.map(UsageFormatter.usdString) ?? "—"
            let tokens = window.totalTokens.map(UsageFormatter.tokenCountString) ?? "—"
            var text = "\(label): \(cost) · \(tokens) tokens"
            if window.incompleteRequestCount > 0 {
                text += " (\(window.incompleteRequestCount) incomplete requests excluded)"
            }
            if window.coverage.unpriced > 0 || window.coverage.unmetered > 0 {
                text += " (some usage has no known price)"
            }
            return text
        }
        let coverage = summary.historyCoverageIsEstablished ? "" : "\nPartial history; scan is incomplete."
        let history = summary.historyDays == 1 ? "" : line("Last \(summary.historyDays) days", summary.history) + "\n"
        return "\(title) — Codex API-equivalent estimate (not billed)\n" +
            line("Today", summary.today) + "\n" + history +
            "Snapshot updated: \(summary.updatedAt.ISO8601Format())\n" +
            "Day boundaries: \(summary.bucketTimeZone)\(coverage)"
    }
}

/// Signals may arrive before the collection task is bound; retain that request until cleanup can run.
final class CodexHostCostCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requestedSignal: Int32?
    private var cancel: (@Sendable () -> Void)?

    var signal: Int32? {
        self.lock.withLock { self.requestedSignal }
    }

    func request(signal: Int32) {
        let cancel = self.lock.withLock {
            if self.requestedSignal == nil { self.requestedSignal = signal }
            return self.cancel
        }
        cancel?()
    }

    func bind(_ cancel: @escaping @Sendable () -> Void) {
        let requested = self.lock.withLock {
            self.cancel = cancel
            return self.requestedSignal != nil
        }
        if requested { cancel() }
    }
}
