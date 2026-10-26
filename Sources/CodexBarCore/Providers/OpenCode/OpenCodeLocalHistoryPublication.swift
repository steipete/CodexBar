import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

extension OpenCodeLocalHistoryAdapter {
    static func refresh(
        scope: ReadScope?,
        cacheRoot: URL?,
        calendar: Calendar) async throws -> Bool
    {
        guard let scope else { return true }
        let store = CostUsageStoreAccess.sharedScanStore(cacheRoot: cacheRoot)
        do {
            let outcome = try await self.runPass(
                databaseURL: URL(fileURLWithPath: scope.path),
                store: store,
                calendar: calendar,
                sinceDay: scope.sinceDay,
                untilDay: scope.untilDay)
            switch outcome {
            case .applied, .skipped(.unchanged): return true
            default: break
            }
        } catch {
            await self.invalidateCoverage(
                store: store,
                path: scope.path)
            if error is CancellationError { throw error }
            return false
        }
        await self.invalidateCoverage(
            store: store,
            path: scope.path)
        return false
    }

    private static func invalidateCoverage(
        store: CostUsageStore,
        path: String) async
    {
        await store.withDatabase(default: ()) { database in
            let statement = try CostUsageStore.prepare(database, """
            UPDATE files SET scan_complete = 0 WHERE path = ?
              AND json_extract(CAST(scan_state AS TEXT), '$.source') = 'opencodeLocalHistory'
            """)
            defer { sqlite3_finalize(statement) }
            CostUsageStore.bind(
                path,
                to: statement,
                at: 1)
            try CostUsageStore.stepDone(
                statement,
                database: database)
        }
    }

    struct ReadScope: Equatable, Sendable {
        var path: String
        var roots: [String]
        var timeZoneIdentifier: String
        var sinceDay: String?
        var untilDay: String?
    }

    static func readScope(
        options: CostUsageScanner.Options,
        environment: [String: String],
        reportContext: CostUsageReportContext? = nil,
        range: CostUsageScanner.CostUsageDayRange? = nil) -> ReadScope?
    {
        guard options.includeOpenCodeLocalHistory, reportContext != .spendDashboard,
              options.codexSessionsRoot == nil,
              environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              let url = self.resolvedDatabaseURL(environment: environment)
        else { return nil }
        return ReadScope(
            path: self.registeredPath(for: url),
            roots: CostUsageScanner.codexSessionsRoots(options: options).map(\.standardizedFileURL.path).sorted(),
            timeZoneIdentifier: options.calendar.timeZone.identifier,
            sinceDay: range?.sinceKey,
            untilDay: range?.untilKey)
    }

    struct StoredSummary: Sendable {
        var scope: ReadScope
        var file: CostUsageStoreFile?
        var aggregates: [CostUsageStoreFileDayAggregate]

        var checkpoint: OpenCodeSourceCheckpoint? {
            OpenCodeSourceCheckpoint.decode(self.file?.scanState.resumePayload)
        }

        var hasRows: Bool {
            self.aggregates.contains { $0.aggregate.requestCount > 0 }
        }

        var hasPendingWork: Bool {
            guard let checkpoint else { return self.file != nil }
            return checkpoint.hasPendingWork || checkpoint.timeZoneIdentifier != self.scope.timeZoneIdentifier
                || (checkpoint.isComplete && self.file?.scanState.isComplete != true)
        }

        var progressKey: String {
            guard let checkpoint else { return "source-unavailable" }
            let part = checkpoint.pendingPartContinuation
            let fingerprint = checkpoint.fingerprint
            let epoch = "\(fingerprint.identity ?? ""):\(fingerprint.modifiedUnixNs ?? fingerprint.modifiedUnixMs)"
                + ":\(fingerprint.walModifiedUnixNs ?? 0):\(fingerprint.size):\(fingerprint.walSize ?? 0)"
            return "\(epoch):\(checkpoint.phase.rawValue):\(checkpoint.position.timestamp):\(checkpoint.position.rowID)"
                + ":\(part?.position.timestamp ?? 0):\(part?.position.rowID ?? 0)"
                + ":\(part?.resumeValidated ?? false):\(part?.needsLegacyLookup ?? false)"
                + ":\(checkpoint.pendingParentCheck?.rowIndex ?? 0)"
        }

        func covers(_ range: CostUsageScanner.CostUsageDayRange) -> Bool {
            guard self.file?.scanState.isComplete == true, let checkpoint,
                  checkpoint.timeZoneIdentifier == range.calendar.timeZone.identifier
            else { return false }
            return (checkpoint.sinceDay == nil || checkpoint.sinceDay! <= range.sinceKey)
                && (checkpoint.untilDay == nil || checkpoint.untilDay! >= range.untilKey)
        }

        func report(_ range: CostUsageScanner.CostUsageDayRange) -> CostUsageDailyReport {
            guard let checkpoint,
                  checkpoint.timeZoneIdentifier == range.calendar.timeZone.identifier,
                  !checkpoint.rebuilding
            else {
                return CostUsageDailyReport(
                    data: [],
                    summary: nil)
            }
            let rows = self.aggregates.filter {
                $0.aggregate.requestCount > 0 && $0.aggregate.day >= range.sinceKey && $0.aggregate.day <= range
                    .untilKey
            }
            return CostUsageDailyReport(
                data: OpenCodeLocalHistoryAdapter
                    .reportEntries(
                        from: rows,
                        tokensComplete: checkpoint.isComplete && !checkpoint.hasUnknownTokens),
                summary: nil)
        }

        static func read(
            _ database: OpaquePointer,
            scope: ReadScope,
            purpose: CostUsageStoreReadPurpose) throws -> Self
        {
            let file = try CostUsageStore.readFile(
                database,
                path: scope.path)
            guard file?.belongsToOpenCodeLocalHistory == true else {
                return Self(
                    scope: scope,
                    file: nil,
                    aggregates: [])
            }
            let aggregates = try purpose == .status ? [] : CostUsageStore.readFileDayAggregates(
                database,
                path: scope.path,
                sinceDay: scope.sinceDay,
                untilDay: scope.untilDay ?? "9999-12-31")
            return Self(
                scope: scope,
                file: file,
                aggregates: aggregates)
        }
    }
}

extension CostUsageFetcher {
    public static func openCodeHistorySourcePath(environment: [String: String]) -> String? {
        OpenCodeLocalHistoryAdapter.resolvedDatabaseURL(environment: environment)
            .map(OpenCodeLocalHistoryAdapter.registeredPath)
    }
}
