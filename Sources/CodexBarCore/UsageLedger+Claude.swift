import Foundation

extension UsageLedgerLoader {
    /// Exports only native Claude usage metadata; conversations and filesystem paths remain local.
    public static func loadClaude(
        historyDays: Int,
        now: Date = Date(),
        calendar: Calendar = .current) async throws -> UsageLedger
    {
        try await CostUsageScanExecutor.run { checkCancellation in
            try self.loadClaude(
                historyDays: historyDays,
                now: now,
                calendar: calendar,
                options: CostUsageScanner.Options(calendar: calendar),
                checkCancellation: checkCancellation)
        }
    }

    /// Synthetic roots and pricing caches keep exporter tests isolated from the user's histories.
    static func loadClaude(
        historyDays: Int,
        now: Date,
        calendar: Calendar,
        options: CostUsageScanner.Options,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> UsageLedger
    {
        guard (1...365).contains(historyDays) else {
            throw UsageLedgerError.invalid("History days must be between 1 and 365.")
        }
        let calendar = CostUsageScanner.CostUsageDayRange.localGregorianCalendar(matching: calendar)
        let today = calendar.startOfDay(for: now)
        guard let since = calendar.date(byAdding: .day, value: 1 - historyDays, to: today) else {
            throw UsageLedgerError.invalid("Unable to establish the requested history window.")
        }
        let range = CostUsageScanner.CostUsageDayRange(since: since, until: now, calendar: calendar)
        let scanned = try CostUsageScanner.claudeLedgerRows(
            range: range, options: options, now: now, checkCancellation: checkCancellation)
        var records: [UsageLedgerRecord] = []
        var incompleteCount = 0
        var overflowCount = 0
        var redactedModel = false
        for (index, row) in scanned.rows.enumerated() {
            try checkCancellation?()
            guard CostUsageScanner.CostUsageDayRange.isInRange(
                dayKey: row.dayKey, since: range.sinceKey, until: range.untilKey)
            else { continue }
            if row.isIncomplete == true {
                incompleteCount += 1
                continue
            }
            guard let timestamp = row.timestampUnixMs,
                  let total = CheckedSum.integers([row.input, row.output, row.cacheRead, row.cacheCreate])
            else {
                overflowCount += 1
                continue
            }
            let identity: UsageLedgerIdentity
            let components: [String]
            if let message = row.messageId, let request = row.requestId,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                identity = .request
                components = ["claude", "request", message, request]
            } else if row.requestId == nil, let message = row.messageId, let session = row.sessionId,
                      !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                identity = .legacyEvent
                components = ["claude", "session-message", session, message]
            } else {
                // Anonymous identifiers distinguish local records only; the merger excludes them globally.
                identity = .unidentified
                components = ["claude", "unidentified", String(index)]
            }
            let isPriced = row.costPriced ?? (row.costNanos > 0)
            let model = Self.claudeLedgerModel(row.model)
            redactedModel = redactedModel || model != row.model
            records.append(UsageLedgerRecord(
                id: UsageLedgerRecord.digest(components),
                sessionID: row.sessionId.map { UsageLedgerRecord.digest(["claude", "session", $0]) },
                identity: identity,
                timestampUnixMs: timestamp,
                model: model,
                inputTokens: row.input,
                cacheReadTokens: row.cacheRead,
                cacheWriteTokens: row.cacheCreate,
                outputTokens: row.output,
                totalTokens: total,
                costUSD: isPriced ? Double(row.costNanos) / 1_000_000_000 : nil,
                cacheWrite1hTokens: row.cacheCreate1h ?? 0,
                costProvenance: isPriced ? .listPriceEstimate : .unknown,
                pricingModel: model))
        }
        var warnings = [
            "Native Claude histories only; Pi/OMP histories are excluded.",
            "Native parsing skips malformed or oversized lines and records without required usage metadata.",
        ]
        if scanned.incompleteSourceCount > 0 {
            warnings.append("\(scanned.incompleteSourceCount) native sources could not be discovered or fully read.")
        }
        if scanned.rejectedUsageLineCount > 0 {
            warnings.append(
                "\(scanned.rejectedUsageLineCount) potentially usage-bearing lines were rejected; coverage is partial.")
        }
        if incompleteCount > 0 {
            warnings.append("\(incompleteCount) incomplete responses are excluded from recorded totals.")
        }
        if overflowCount > 0 {
            warnings.append("\(overflowCount) responses have unavailable timestamps or overflowing token totals.")
        }
        if redactedModel {
            warnings.append("Non-identifier model metadata was redacted from the numeric export.")
        }
        if records.contains(where: { $0.identity == .legacyEvent }) {
            warnings.append("Legacy Claude responses lack provider request IDs; identity relies on session provenance.")
        }
        if records.contains(where: { $0.identity == .unidentified }) {
            warnings.append("Some Claude records lack stable identity and cannot be deduplicated across hosts.")
        }
        try checkCancellation?()
        var ledger = UsageLedger(
            provider: UsageProvider.claude.rawValue,
            updatedAt: Date(),
            historyDays: historyDays,
            bucketTimeZone: calendar.timeZone.identifier,
            coverageIsEstablished: scanned.incompleteSourceCount == 0 && overflowCount == 0
                && scanned.rejectedUsageLineCount == 0,
            records: records,
            incompleteRequestCount: incompleteCount,
            warnings: warnings)
        ledger.windowStartUnixMs = Int64(since.timeIntervalSince1970 * 1000)
        ledger.windowEndUnixMs = Int64(now.timeIntervalSince1970 * 1000)
        return ledger
    }

    /// Transcript-controlled strings must be identifiers, never arbitrary paths or conversation text.
    private static func claudeLedgerModel(_ model: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !model.isEmpty, model.utf8.count <= 128,
              model.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else { return "unknown" }
        return model
    }
}
