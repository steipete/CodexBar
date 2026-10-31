import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    /// Explicit JSON-only experiment; ordinary cost commands and saved reporting preferences are untouched.
    static func runCodexIdentifiedUsage(_ values: ParsedValues, output: CLIOutputPreferences) async {
        let days = values.options["days"]?.last.flatMap(Int.init) ?? 30
        let end = values.options["identifiedEnd"]?.last.flatMap(Int64.init)
            ?? Int64((Date().timeIntervalSince1970 * 1000).rounded())
        let hosts = values.options["remote"] ?? []
        // Provider-specific by design: this native strong-identity export supports only explicit Codex JSON.
        guard values.flags.contains("identifiedOnly"), values.options["provider"] == ["codex"],
              output.format == .json, (1...365).contains(days), (0...253_402_300_799_999).contains(end),
              values.options["period"] == nil, values.options["groupBy"] == nil,
              !values.flags.contains("summaryOnly"), !values.flags.contains("breakdown"),
              ["days", "identifiedEnd"].allSatisfy({ (values.options[$0]?.count ?? 0) <= 1 }),
              values.options["days"] == nil || values.options["days"]?.last.flatMap(Int.init) != nil,
              values.options["identifiedEnd"] == nil || values.options["identifiedEnd"]?.last.flatMap(Int64.init) != nil
        else {
            Self.exit(
                code: .failure,
                message: "Use --identified-only --provider codex with JSON, --days 1...365 and optional " +
                    "repeated --remote hosts. --identified-end must be Unix milliseconds; " +
                    "period, grouping, breakdown and separate host summaries are unsupported.",
                output: output,
                kind: .args)
        }
        guard let start = CodexIdentifiedCollection.window(days: days, endUnixMs: end) else {
            Self.exit(code: .failure, message: "Invalid UTC history window.", output: output, kind: .args)
        }
        for host in hosts {
            do { try RemoteCodexCostFetcher.validateHost(host) } catch {
                Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .args)
            }
        }
        let cancellation = CodexHostCostCancellation()
        let monitor = CLITerminationSignalMonitor { cancellation.request(signal: $0) }
        let operation = Task {
            try await CodexIdentifiedCollection.collect(
                remotes: hosts,
                startUnixMs: start,
                endUnixMs: end,
                pretty: output.pretty,
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
            if hosts.isEmpty, let localJSON = report.localLedgerJSON {
                print(localJSON)
            } else {
                Self.printJSON(report, pretty: output.pretty)
            }
            Self.exit(code: report.allSourcesAvailable ? .success : .failure, output: output, kind: .provider)
        } catch {
            Self.exit(code: .failure, message: "Identified Codex collection cancelled or unavailable.", output: output)
        }
    }
}
