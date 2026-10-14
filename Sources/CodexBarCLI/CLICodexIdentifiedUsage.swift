import CodexBarCore
import Commander
import Foundation

struct CodexIdentifiedSource: Codable, Sendable {
    let host: String
    let ledger: CodexRequestLedger?
    let error: String?
}

struct CodexIdentifiedResult: Codable, Sendable {
    let reports: [CodexIdentifiedSource]
    let subtotal: CodexRequestSubtotal?
    let allSourcesAvailable: Bool
    let partial: Bool
}

extension CodexBarCLI {
    /// Explicit JSON-only experiment; ordinary cost commands and saved reporting preferences are untouched.
    static func runCodexIdentifiedUsage(_ values: ParsedValues, output: CLIOutputPreferences) async {
        let days = values.options["days"]?.last.flatMap(Int.init) ?? 30
        let end = values.options["identifiedEnd"]?.last.flatMap(Int64.init)
            ?? Int64((Date().timeIntervalSince1970 * 1000).rounded())
        let host = values.options["remote"]?.last
        // Provider-specific by design: this native strong-identity export supports only explicit Codex JSON.
        guard values.flags.contains("identifiedOnly"), values.options["provider"] == ["codex"],
              output.format == .json, (1...365).contains(days), (0...253_402_300_799_999).contains(end),
              values.options["period"] == nil, values.options["groupBy"] == nil,
              !values.flags.contains("summaryOnly"), !values.flags.contains("breakdown"),
              ["days", "identifiedEnd", "remote"].allSatisfy({ (values.options[$0]?.count ?? 0) <= 1 }),
              values.options["days"] == nil || values.options["days"]?.last.flatMap(Int.init) != nil,
              values.options["identifiedEnd"] == nil || values.options["identifiedEnd"]?.last.flatMap(Int64.init) != nil
        else {
            Self.exit(
                code: .failure,
                message: "Use --identified-only --provider codex with JSON, --days 1...365 and one optional " +
                    "--remote host. --identified-end must be Unix milliseconds; " +
                    "period, grouping, breakdown and separate host summaries are unsupported.",
                output: output,
                kind: .args)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let endDate = Date(timeIntervalSince1970: Double(end) / 1000)
        guard let startDate = calendar.date(byAdding: .day, value: 1 - days, to: calendar.startOfDay(for: endDate)),
              startDate.timeIntervalSince1970 >= 0
        else { Self.exit(code: .failure, message: "Invalid UTC history window.", output: output, kind: .args) }
        let start = Int64(startDate.timeIntervalSince1970 * 1000)
        if let host {
            do { try RemoteCodexCostFetcher.validateHost(host) } catch {
                Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .args)
            }
        }
        let cancellation = CodexHostCostCancellation()
        let monitor = CLITerminationSignalMonitor { cancellation.request(signal: $0) }
        let operation = Task {
            try await Self.collectCodexIdentifiedUsage(
                remote: host,
                startUnixMs: start,
                endUnixMs: end,
                local: { try await CodexRequestLedger.load(startUnixMs: start, endUnixMs: end) },
                fetchRemote: {
                    try await RemoteCodexCostFetcher().fetchIdentifiedUsage(
                        host: $0, historyDays: days, startUnixMs: start, endUnixMs: end)
                })
        }
        cancellation.bind { operation.cancel() }
        let result = await operation.result
        monitor.cancel()
        if let signal = cancellation.signal {
            CLITerminationSignalMonitor.terminateActiveHelpersAndReraise(signal)
            return
        }
        do {
            let report = try result.get()
            if host == nil, let ledger = report.reports.first?.ledger {
                Self.printJSON(ledger, pretty: output.pretty)
            } else {
                Self.printJSON(report, pretty: output.pretty)
            }
            Self.exit(code: report.allSourcesAvailable ? .success : .failure, output: output, kind: .provider)
        } catch {
            Self.exit(code: .failure, message: "Identified Codex collection cancelled or unavailable.", output: output)
        }
    }

    /// Preserve available identified requests when a source fails; cancellation prevents further SSH work.
    static func collectCodexIdentifiedUsage(
        remote: String?,
        startUnixMs: Int64,
        endUnixMs: Int64,
        local: @Sendable () async throws -> CodexRequestLedger,
        fetchRemote: @Sendable (String) async throws -> CodexRequestLedger) async throws -> CodexIdentifiedResult
    {
        var reports: [CodexIdentifiedSource] = []
        var subtotal: CodexRequestSubtotal?
        for host in ["local"] + (remote.map { [$0] } ?? []) {
            try Task.checkCancellation()
            do {
                let ledger = try await (reports.isEmpty ? local() : fetchRemote(host))
                try ledger.validate(startUnixMs: startUnixMs, endUnixMs: endUnixMs)
                // Reject an overflowing source or union while the earlier sources remain available.
                subtotal = try CodexRequestLedger.merge(reports.compactMap(\.ledger) + [ledger])
                reports.append(.init(host: host, ledger: ledger, error: nil))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                reports.append(.init(
                    host: host,
                    ledger: nil,
                    error: reports.isEmpty
                        ? "Local native Codex identified usage is unavailable."
                        :
                        "Remote identified usage is unavailable. Check SSH and update its CLI for --identified-only."))
            }
        }
        try Task.checkCancellation()
        let available = reports.allSatisfy { $0.ledger != nil }
        return CodexIdentifiedResult(
            reports: reports,
            subtotal: subtotal,
            allSourcesAvailable: available,
            partial: !available || subtotal?.partial != false)
    }
}
