import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    /// Route explicit ledger modes before normal cost handling can load account configuration.
    static func runCost(_ values: ParsedValues) async {
        let output = CLIOutputPreferences.from(values: values)
        if values.flags.contains("ledgerOnly") || values.options["combineRemote"] != nil {
            await self.runUsageLedger(values, output: output)
            return
        }
        guard values.options["ledgerTimeZone"] == nil, values.options["ledgerEnd"] == nil else {
            exit(
                code: .failure,
                message: "Ledger window options require --ledger-only or --combine-remote.",
                output: output,
                kind: .args)
        }
        await Self.runStandardCost(values)
    }

    static func runUsageLedger(_ values: ParsedValues, output: CLIOutputPreferences) async {
        let ledgerOnly = values.flags.contains("ledgerOnly")
        let host = values.options["combineRemote"]?.last
        let providerName = values.options["provider"]?.last
        guard let providerName, ["codex", "claude"].contains(providerName),
              !(ledgerOnly && host != nil), !ledgerOnly || output.format == .json,
              values.options["provider"]?.count == 1, (values.options["combineRemote"]?.count ?? 0) <= 1,
              values.options["remote"] == nil, !values.flags.contains("summaryOnly"),
              values.options["groupBy"] == nil, values.options["period"] == nil,
              !values.flags.contains("breakdown")
        else {
            Self.exit(
                code: .failure,
                message: "Use one --provider codex|claude with --ledger-only --format json or --combine-remote host. " +
                    "Ledger modes do not accept --remote, --summary-only, --period, --group-by or --breakdown.",
                output: output,
                kind: .args)
        }
        let days = values.options["days"]?.last.flatMap(Int.init) ?? 30
        let zone = values.options["ledgerTimeZone"]?.last ?? TimeZone.current.identifier
        let end = values.options["ledgerEnd"]?.last.flatMap(Int64.init)
        guard (1...365).contains(days), TimeZone(identifier: zone) != nil,
              values.options["days"] == nil || values.options["days"]?.last.flatMap(Int.init) != nil,
              values.options["ledgerEnd"] == nil || end != nil,
              end.map({ (0...253_402_300_799_000).contains($0) }) ?? true
        else {
            Self.exit(code: .failure, message: "Invalid ledger reporting window.", output: output, kind: .args)
        }
        let now = end.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date()
        let calendar = CostUsageBucketTimeZone.calendar(identifier: zone)
        let provider: UsageProvider = providerName == "codex" ? .codex : .claude
        let cancellation = CodexHostCostCancellation()
        let monitor = CLITerminationSignalMonitor { signal in cancellation.request(signal: signal) }
        let operation = Task {
            if ledgerOnly {
                let ledger = try await UsageLedgerLoader.load(
                    provider: provider, historyDays: days, now: now, calendar: calendar)
                try ledger.validate(provider: providerName, historyDays: days)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                if output.pretty { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
                let data = try encoder.encode(ledger)
                guard data.count <= UsageLedger.maximumOutputBytes else {
                    throw UsageLedgerError.invalid("Usage ledger exceeds the export size limit.")
                }
                guard let json = String(data: data, encoding: .utf8) else {
                    throw UsageLedgerError.invalid("Unable to encode the numeric usage ledger.")
                }
                print(json)
                return true
            }
            guard let host else { throw UsageLedgerError.invalid("A remote host is required.") }
            let report = try await UsageLedgerCollector.collect(
                provider: provider, host: host, historyDays: days, calendar: calendar, now: now)
            if output.format == .json {
                Self.printJSON(report, pretty: output.pretty)
            } else {
                print(Self.renderUsageLedgerReport(report))
            }
            return report.reports.allSatisfy { $0.error == nil }
        }
        cancellation.bind { operation.cancel() }
        let result = await operation.result
        monitor.cancel()
        if let signal = cancellation.signal {
            CLITerminationSignalMonitor.terminateActiveHelpersAndReraise(signal)
            return
        }
        do {
            let success = try result.get()
            Self.exit(code: success ? .success : .failure, output: output, kind: .provider)
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .runtime)
        }
    }

    static func renderUsageLedgerReport(_ report: CombinedUsageLedgerReport) -> String {
        let totals = report.combined
        let label = totals.coverageIsEstablished ? "Recorded usage" : "Recorded subtotal (partial coverage)"
        let cost = totals.costUSD.map { UsageFormatter.currencyString($0, currencyCode: "USD") } ?? "unavailable"
        var lines = [
            "\(report.provider) · experimental cross-host native history",
            "\(label): \(totals.totalTokens) tokens · API-rate cost: \(cost)",
            "Copies removed: \(totals.duplicateCount); conflicting identities: \(totals.conflictCount); " +
                "unidentified/ambiguous records withheld: \(totals.unidentifiedCount)",
            "Legacy event identities: \(totals.legacyIdentityCount); " +
                "missing/conflicting prices: \(totals.unpricedCount)",
        ]
        for source in report.reports {
            guard let ledger = source.ledger else {
                lines.append("\(source.host): \(source.error ?? "unavailable")")
                continue
            }
            lines.append("\(source.host): \(ledger.records.count) records · " +
                "snapshot \(ISO8601DateFormatter().string(from: ledger.updatedAt))")
            lines.append(contentsOf: ledger.warnings.map { "  \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}
