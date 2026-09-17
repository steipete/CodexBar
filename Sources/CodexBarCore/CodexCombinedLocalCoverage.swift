import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

/// No StoreAccess, migration, schema repair or legacy-artifact cleanup is allowed on the normal ledger.
enum CodexCombinedLocalCoverage {
    @discardableResult
    static func validate(request: CodexCombinedCostRequest, since: Date) throws -> CodexCombinedPriorityEvidence {
        var evidence = CodexCombinedPriorityEvidence()
        let root = request.localCostCacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("CodexBar", isDirectory: true)
        let directory = root.appendingPathComponent("cost-usage", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("codex-v11.json").path) else {
            throw CodexCombinedCostError.localCoverage
        }
        let url = directory.appendingPathComponent(CostUsageStore.databaseFilename)
        guard FileManager.default.fileExists(atPath: url.path) else { return evidence }
        var opened: OpaquePointer?
        guard sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database = opened else {
            if let opened { sqlite3_close(opened) }
            throw CodexCombinedCostError.localCoverage
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)
        do {
            guard sqlite3_exec(database, "BEGIN", nil, nil, nil) == SQLITE_OK else {
                throw CodexCombinedCostError.localCoverage
            }
            defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
            let files = try CostUsageStore.readFiles(database)
            let aggregates = try CostUsageStore.readFileDayAggregates(database, path: nil)
            let sinceKey = CostUsageLocalDay.key(from: since, calendar: request.calendar)
            let untilKey = CostUsageLocalDay.key(from: request.now, calendar: request.calendar)
            let metadata = try CostUsageStore.readSingleton(
                CostUsageStoreMetadata.self, database: database, table: "scan_metadata")
            let sameCalendar = metadata?.timeZoneIdentifier == request.calendar.timeZone.identifier
            let relevantPaths = sameCalendar ? Set(aggregates.filter {
                $0.aggregate.day >= sinceKey && $0.aggregate.day <= untilKey
            }.map(\.path)) : Set(files.map(\.path))
            let scopedPaths = try self.scopedPaths(
                files: files,
                relevantPaths: relevantPaths,
                ledgerRoots: metadata?.rootMtimes,
                home: request.localCodexHome)
            let range = CostUsageScanner.CostUsageDayRange(since: since, until: request.now, calendar: request.calendar)
            let byPath = Dictionary(grouping: aggregates, by: \.path)
            for file in files where scopedPaths.contains(file.path) {
                let metadata = CostUsageScanner.codexFileMetadata(fileURL: URL(fileURLWithPath: file.path))
                // A changed/truncated source requires a normal local refresh before this strict coverage check.
                let inode = metadata.fileId?.split(separator: ":").last.flatMap { Int64($0) }
                guard metadata.fileId != nil, inode == file.inode, metadata.size == file.size,
                      metadata.mtimeUnixMs == file.mtimeUnixMs
                else {
                    throw CodexCombinedCostError.localCoverage
                }
                let rows = try CostUsageStore.readUsageRows(database, path: file.path).map {
                    try JSONDecoder().decode(CostUsageScanner.CodexUsageRow.self, from: $0.payload)
                }
                try evidence.retain(
                    file: file, rows: rows, aggregates: (byPath[file.path] ?? []).map(\.aggregate), range: range)
            }
            return evidence
        } catch let error as CodexCombinedCostError {
            throw error
        } catch {
            throw CodexCombinedCostError.localCoverage
        }
    }

    private static func scopedPaths(
        files: [CostUsageStoreFile],
        relevantPaths: Set<String>,
        ledgerRoots: [String: Int64]?,
        home: URL) throws -> Set<String>
    {
        guard !relevantPaths.isEmpty else { return [] }
        let homePath = self.resolvedPath(home) + "/"
        let roots = (ledgerRoots ?? [:]).keys.map { self.resolvedPath(URL(fileURLWithPath: $0)) }
        // A retargeted alias must not silently turn an older ledger into an unrelated empty baseline.
        guard roots.contains(where: { $0.hasPrefix(homePath) }) else {
            throw CodexCombinedCostError.localCoverage
        }
        let otherRoots = roots.filter { !$0.hasPrefix(homePath) }.map { $0 + "/" }
        var scoped = Set<String>()
        for file in files where relevantPaths.contains(file.path) {
            let path = self.resolvedPath(URL(fileURLWithPath: file.path))
            if path.hasPrefix(homePath) {
                scoped.insert(file.path)
            } else if !otherRoots.contains(where: { path.hasPrefix($0) }) {
                // No recorded scope explains this retained row after resolving current aliases.
                throw CodexCombinedCostError.localCoverage
            }
        }
        return scoped
    }

    /// Resolve existing parents explicitly: Foundation need not resolve a symlink when the leaf was deleted.
    private static func resolvedPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var missingComponents: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            missingComponents.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in missingComponents.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL.path
    }
}
