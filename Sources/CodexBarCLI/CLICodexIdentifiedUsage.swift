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
        // Provider-specific by design: only Codex, Claude and Pi expose native strong request identities.
        let provider = values.options["provider"]?.first ?? "codex"
        guard values.flags.contains("identifiedOnly"), values.options["provider"]?.count == 1,
              ["codex", "claude", "pi"].contains(provider),
              output.format == .json, hosts.count < IdentifiedRequestLimits.maximumSources, (1...365).contains(days),
              (0...253_402_300_799_999).contains(end),
              values.options["period"] == nil, values.options["groupBy"] == nil,
              !values.flags.contains("summaryOnly"), !values.flags.contains("breakdown"),
              ["days", "identifiedEnd"].allSatisfy({ (values.options[$0]?.count ?? 0) <= 1 }),
              values.options["days"] == nil || values.options["days"]?.last.flatMap(Int.init) != nil,
              values.options["identifiedEnd"] == nil || values.options["identifiedEnd"]?.last.flatMap(Int64.init) != nil
        else {
            Self.exit(
                code: .failure,
                message: "Use --identified-only --provider codex, --provider claude or --provider pi with JSON, " +
                    "--days 1...365 and optional " +
                    "repeated --remote hosts. --identified-end must be Unix milliseconds; " +
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
        for host in hosts {
            do { try RemoteCodexCostFetcher.validateHost(host) } catch {
                Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .args)
            }
        }
        // Provider-specific by design: Pi owns its native scanner and process-context selection.
        if provider == "pi" {
            let contexts = await Self.piSessionProcessContextsForCost(providers: [.pi], includePiSessions: true)
            await Self.runIdentifiedCollection(
                hosts: hosts,
                window: start...end,
                output: output,
                local: { try await PiRequestLedger.load(
                    startUnixMs: start, endUnixMs: end, processContexts: contexts) },
                fetchRemote: { try await RemoteCodexCostFetcher().fetchIdentifiedUsage(
                    host: $0, historyDays: days, startUnixMs: start, endUnixMs: end, ledgerType: PiRequestLedger.self)
                })
        } else if provider == "claude" {
            await Self.runIdentifiedCollection(
                hosts: hosts,
                window: start...end,
                output: output,
                local: { try await ClaudeRequestLedger.load(startUnixMs: start, endUnixMs: end) },
                fetchRemote: { try await RemoteCodexCostFetcher().fetchIdentifiedUsage(
                    host: $0,
                    historyDays: days,
                    startUnixMs: start,
                    endUnixMs: end,
                    ledgerType: ClaudeRequestLedger.self) })
        } else {
            await Self.runIdentifiedCollection(
                hosts: hosts,
                window: start...end,
                output: output,
                local: { try await CodexRequestLedger.load(startUnixMs: start, endUnixMs: end) },
                fetchRemote: { try await RemoteCodexCostFetcher().fetchIdentifiedUsage(
                    host: $0, historyDays: days, startUnixMs: start, endUnixMs: end) })
        }
    }

    private static func runIdentifiedCollection<Ledger: IdentifiedRequestLedger>(
        hosts: [String],
        window: ClosedRange<Int64>,
        output: CLIOutputPreferences,
        local: @escaping @Sendable () async throws -> Ledger,
        fetchRemote: @escaping @Sendable (String) async throws -> Ledger) async
    {
        let cancellation = CodexHostCostCancellation()
        let monitor = CLITerminationSignalMonitor { cancellation.request(signal: $0) }
        let operation = Task {
            try await IdentifiedCostCollection.collect(
                remotes: hosts,
                startUnixMs: window.lowerBound,
                endUnixMs: window.upperBound,
                pretty: output.pretty,
                local: local,
                fetchRemote: fetchRemote)
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
            Self.exit(
                code: .failure,
                message: "Identified \(Ledger.providerName.capitalized) collection cancelled or unavailable.",
                output: output)
        }
    }
}
