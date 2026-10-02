import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    static func isCodexDailySummaryRequest(_ values: ParsedValues) -> Bool {
        values.flags.contains("dailySummary") || values.options["bucketTimeZone"] != nil
    }

    static func codexDailySummaryCalendar(_ values: ParsedValues, format: OutputFormat) throws -> Calendar {
        guard values.flags.contains("dailySummary"), values.flags.contains("providerNativeOnly"),
              values.options["provider"] == ["codex"], format == .json,
              !values.flags.contains("summaryOnly"), !values.flags.contains("breakdown"),
              values.options["remote"] == nil, values.options["groupBy"] == nil, values.options["period"] == nil,
              values.options["bucketTimeZone"]?.count == 1,
              let identifier = values.options["bucketTimeZone"]?.first
        else { throw RemoteCodexCostError.invalidReport }
        return try CodexCostDailySummary.calendar(bucketTimeZone: identifier)
    }

    static func runCodexDailySummary(
        _ values: ParsedValues,
        historyDays: Int,
        output: CLIOutputPreferences) async
    {
        let calendar: Calendar
        do {
            calendar = try Self.codexDailySummaryCalendar(values, format: output.format)
        } catch {
            Self.exit(
                code: .failure,
                message: "Use --daily-summary with --provider codex --format json --provider-native-only " +
                    "and one valid --bucket-time-zone. It cannot be combined with --remote, --summary-only, " +
                    "--group-by, --period, or --breakdown.",
                output: output,
                kind: .args)
        }
        let force = values.flags.contains("refresh")
        let cancellation = CodexHostCostCancellation()
        let monitor = CLITerminationSignalMonitor { signal in cancellation.request(signal: signal) }
        let operation = Task {
            try Task.checkCancellation()
            let snapshot = try await CostUsageFetcher(calendar: calendar).loadTokenSnapshot(
                provider: .codex,
                forceRefresh: force,
                historyDays: historyDays,
                refreshPricingInBackground: false,
                includePiSessions: false)
            try Task.checkCancellation()
            return try CodexCostDailySummary(snapshot: snapshot, calendar: calendar)
        }
        cancellation.bind { operation.cancel() }
        let result = await operation.result
        monitor.cancel()
        if let signal = cancellation.signal {
            CLITerminationSignalMonitor.terminateActiveHelpersAndReraise(signal)
            return
        }
        do {
            try Self.printJSON([result.get()], pretty: output.pretty)
        } catch {
            // Scanner errors may include local paths. The transport exposes only this fixed failure.
            Self.exit(
                code: .failure, message: "Native Codex daily history is unavailable.", output: output, kind: .provider)
        }
        Self.exit(code: .success, output: output, kind: .runtime)
    }
}
