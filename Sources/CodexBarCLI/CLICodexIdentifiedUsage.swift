import CodexBarCore
import Commander
import Foundation

struct CodexIdentifiedSource: Codable, Sendable {
    let host: String
    let source: String
    let collectedAt: Date?
    let ledger: CodexRequestLedger?
    let error: String?
}

struct CodexIdentifiedResult: Codable, Sendable {
    let reports: [CodexIdentifiedSource]
    let subtotal: CodexRequestSubtotal?
    let allSourcesAvailable: Bool
    let partial: Bool
    var localLedgerJSON: String?

    enum CodingKeys: String, CodingKey {
        case reports, subtotal, allSourcesAvailable, partial
    }
}

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
        let cancellation = CodexHostCostCancellation()
        let monitor = CLITerminationSignalMonitor { cancellation.request(signal: $0) }
        let operation = Task {
            try await Self.collectCodexIdentifiedUsage(
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

    /// Preserve available identified requests when a source fails; cancellation prevents further SSH work.
    static func collectCodexIdentifiedUsage(
        remotes: [String],
        startUnixMs: Int64,
        endUnixMs: Int64,
        pretty: Bool = false,
        now: @Sendable () -> Date = { Date() },
        local: @Sendable () async throws -> CodexRequestLedger,
        fetchRemote: @Sendable (String) async throws -> CodexRequestLedger) async throws -> CodexIdentifiedResult
    {
        var reports: [CodexIdentifiedSource] = []
        var subtotal: CodexRequestSubtotal?
        var localLedgerJSON: String?
        let merge = remotes.isEmpty ? nil : CodexRequestLedger.makeMerger()
        let hosts = ["local"] + remotes
        for (sourceIndex, host) in hosts.enumerated() {
            try Task.checkCancellation()
            do {
                let ledger = try await (sourceIndex == 0 ? local() : fetchRemote(host))
                try Task.checkCancellation()
                try ledger.validate(startUnixMs: startUnixMs, endUnixMs: endUnixMs)
                // Bound local producer output; remote bytes were already bounded by the SSH reader.
                if sourceIndex == 0 {
                    guard let json = Self.encodeJSON(ledger, pretty: pretty) else {
                        throw RemoteCodexCostError.invalidReport
                    }
                    if remotes.isEmpty { localLedgerJSON = json }
                }
                if let merge {
                    // Reject an overflowing union while the earlier sources remain available.
                    subtotal = try merge(reports.compactMap(\.ledger) + [ledger])
                }
                reports.append(.init(
                    host: host,
                    source: sourceIndex == 0 ? "local" : "ssh",
                    collectedAt: now(),
                    ledger: ledger,
                    error: nil))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                reports.append(.init(
                    host: host,
                    source: sourceIndex == 0 ? "local" : "ssh",
                    collectedAt: nil,
                    ledger: nil,
                    error: sourceIndex == 0
                        ? "Local native Codex identified usage is unavailable."
                        :
                        "Remote identified usage is unavailable. Check SSH and update its CLI " +
                        "for schema 2 --identified-only."))
            }
        }
        try Task.checkCancellation()
        let available = reports.allSatisfy { $0.ledger != nil }
        return CodexIdentifiedResult(
            reports: reports,
            subtotal: subtotal,
            allSourcesAvailable: available,
            partial: !available || (subtotal?.partial ?? false),
            localLedgerJSON: localLedgerJSON)
    }
}
