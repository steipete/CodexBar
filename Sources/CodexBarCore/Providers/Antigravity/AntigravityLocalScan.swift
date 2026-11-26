import Foundation

extension AntigravityLocalReader {
    struct Context: Sendable {
        let home: URL
        let additionalProfileHomes: [String]
        @ProcessEnvironment private(set) var environment: [String: String]

        init(environment: [String: String], additionalProfileHomes: [String] = []) {
            self.additionalProfileHomes = additionalProfileHomes
            self.environment = environment
            self.home = environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser
        }

        var databaseRoots: [URL] {
            AntigravityOfflineStore.geminiHomeDirectories(
                home: self.home, env: self.environment, additionalProfileHomes: self.additionalProfileHomes)
                .flatMap { home in
                    ["antigravity-cli/conversations", "antigravity", "antigravity/conversations"].map {
                        home.appendingPathComponent($0, isDirectory: true)
                    }
                }
        }

        var cacheRoot: URL {
            let config = self.environment["TOKSCALE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? self.home.appendingPathComponent(".config/tokscale", isDirectory: true)
            return config.appendingPathComponent("antigravity-cache/sessions", isDirectory: true)
        }
    }

    struct Limits: Sendable {
        var databases = 2000
        var directoryEntries = 20000
        var rowsPerDatabase = 10000
        var rows = 500_000
        var blobBytes = 16 * 1024 * 1024
        var databaseBytes = 64 * 1024 * 1024
        var bytes = 2 * 1024 * 1024 * 1024
        var schemaEntries = 128
        var schemaColumns = 64
        var schemaBytes = 64 * 1024
        var duration: TimeInterval = 120
    }

    struct Statistics: Sendable {
        var directoryEntries = 0
        var files = 0
        var rows = 0
        var attemptedBytes = 0
        var materializedPayloadBytes = 0
        var schemaEntries = 0
        var schemaColumns = 0
        var schemaBytes = 0
        var sqliteHandlesOpened = 0
        var sqliteHandlesClosed = 0
        /// Sidecar-less WAL databases that the ordinary read-only open declined and an immutable open read.
        var immutableFallbacks = 0
        /// Databases in a declared root whose schema has no gen_metadata table; skipped without affecting coverage.
        var foreignDatabases = 0
    }

    enum ScanFailure: Error {
        case exhausted
        /// Schema-budget exhaustion (bytes, entries, or columns). Unlike hard row/byte/duration exhaustion,
        /// schema exhaustion preserves already-decoded rows as partial history instead of withholding the report.
        case schemaExhausted
        case invalid
    }

    /// One budget belongs to one executor job, including discovery and fallback.
    final class Budget {
        let limits: Limits
        let cancellation: () throws -> Void
        let clock: () -> TimeInterval
        let started: TimeInterval
        var statistics = Statistics()
        /// Schema text inspected in the current database. The schema allowance applies to each database,
        /// like the entry and column limits, so a long history of small schemas never adds up to it.
        private(set) var databaseSchemaBytes = 0
        private(set) var durationExhausted = false

        var isJobExhausted: Bool {
            self.statistics.rows >= self.limits.rows
                || self.statistics.attemptedBytes >= self.limits.bytes
                || self.durationExhausted
        }

        init(
            limits: Limits,
            clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
            cancellation: @escaping () throws -> Void)
        {
            self.limits = limits
            self.clock = clock
            self.started = clock()
            self.cancellation = cancellation
        }

        func check() throws {
            try self.cancellation()
            guard self.clock() - self.started < self.limits.duration else {
                self.durationExhausted = true
                throw ScanFailure.exhausted
            }
        }

        func chargeBytes(_ count: Int) throws {
            try self.check()
            let (attempted, overflow) = self.statistics.attemptedBytes.addingReportingOverflow(count)
            self.statistics.attemptedBytes = overflow ? Int.max : attempted
            guard !overflow, attempted <= self.limits.bytes else { throw ScanFailure.exhausted }
        }

        func chargeRow() throws {
            try self.check()
            self.statistics.rows += 1
            guard self.statistics.rows <= self.limits.rows else { throw ScanFailure.exhausted }
        }

        func beginDatabase() {
            self.databaseSchemaBytes = 0
        }

        func chargeSchemaBytes(_ count: Int) throws {
            try self.check()
            let (total, totalOverflow) = self.statistics.schemaBytes.addingReportingOverflow(count)
            self.statistics.schemaBytes = totalOverflow ? Int.max : total
            let (attempted, overflow) = self.databaseSchemaBytes.addingReportingOverflow(count)
            self.databaseSchemaBytes = overflow ? Int.max : attempted
            guard !overflow, attempted <= self.limits.schemaBytes else { throw ScanFailure.schemaExhausted }
        }
    }

    struct Discovery {
        var paths: [URL] = []
        var skippedOldPaths: [URL] = []
        var isComplete = true
    }

    static func discover(
        roots: [URL],
        extension suffix: String,
        budget: Budget,
        dayRange: (sinceKey: String, untilKey: String)? = nil,
        calendar: Calendar = .current) throws -> Discovery
    {
        var result = Discovery()
        var candidates: [(url: URL, modifiedAt: Date?)] = []
        var skippedCandidates: [(url: URL, modifiedAt: Date?)] = []
        let sinceDate = dayRange.flatMap { CostUsageLocalDay.date(fromKey: $0.sinceKey, calendar: calendar) }
        var hitDirectoryEntryLimit = false

        for root in roots {
            try budget.check()
            do {
                let values = try root.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else {
                    result.isComplete = false
                    continue
                }
            } catch {
                // ENOENT means absent. Permission errors and invalid roots must block fallback.
                if (error as NSError).code == NSFileReadNoSuchFileError { continue }
                result.isComplete = false
                continue
            }
            var enumerationFailed = false
            guard let enumerator = FileManager.default.enumerator(
                at: root.resolvingSymlinksInPath(),
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsSubdirectoryDescendants],
                errorHandler: { _, _ in
                    enumerationFailed = true
                    return false
                })
            else {
                result.isComplete = false
                continue
            }
            while true {
                try budget.check()
                guard let url = enumerator.nextObject() as? URL else { break }
                budget.statistics.directoryEntries += 1
                if budget.statistics.directoryEntries > budget.limits.directoryEntries {
                    result.isComplete = false
                    hitDirectoryEntryLimit = true
                    break
                }
                guard !url.lastPathComponent.hasPrefix("."), url.pathExtension.lowercased() == suffix else { continue }
                do {
                    let resolvedURL = url.resolvingSymlinksInPath()
                    let values = try resolvedURL.resourceValues(
                        forKeys: [.isRegularFileKey, .contentModificationDateKey])
                    guard values.isRegularFile == true else {
                        result.isComplete = false
                        continue
                    }
                    let effectiveMtime = self.effectiveModificationDate(
                        resolvedURL: resolvedURL,
                        fileMtime: values.contentModificationDate,
                        extension: suffix)
                    if let sinceDate, let effectiveMtime, effectiveMtime < sinceDate {
                        skippedCandidates.append((url: url, modifiedAt: effectiveMtime))
                        continue
                    }
                    candidates.append((url: url, modifiedAt: effectiveMtime))
                } catch {
                    result.isComplete = false
                }
            }
            if enumerationFailed { result.isComplete = false }
            if hitDirectoryEntryLimit { break }
        }

        let sortCandidates: ((url: URL, modifiedAt: Date?), (url: URL, modifiedAt: Date?)) -> Bool = { lhs, rhs in
            let lhsDate = lhs.modifiedAt ?? .distantPast
            let rhsDate = rhs.modifiedAt ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.url.path < rhs.url.path
        }
        candidates.sort(by: sortCandidates)
        skippedCandidates.sort(by: sortCandidates)
        result.skippedOldPaths = skippedCandidates.map(\.url)
        let limit = max(0, budget.limits.databases)
        if candidates.count > limit {
            result.isComplete = false
            result.paths = candidates.prefix(limit).map(\.url)
        } else {
            result.paths = candidates.map(\.url)
        }
        return result
    }

    private static func effectiveModificationDate(
        resolvedURL: URL,
        fileMtime: Date?,
        extension suffix: String) -> Date?
    {
        guard suffix == "db" else { return fileMtime }
        let walPath = resolvedURL.path + "-wal"
        let walMtime = (try? FileManager.default.attributesOfItem(atPath: walPath))?[.modificationDate] as? Date
        switch (fileMtime, walMtime) {
        case let (.some(dbDate), .some(walDate)):
            return max(dbDate, walDate)
        case let (.some(dbDate), .none):
            return dbDate
        case let (.none, .some(walDate)):
            return walDate
        case (.none, .none):
            return nil
        }
    }
}

extension CostUsageFetcher {
    package static func antigravityHistoryScope(
        environment: [String: String], additionalProfileHomes: [String]) -> String
    {
        let context = AntigravityLocalReader.Context(
            environment: environment, additionalProfileHomes: additionalProfileHomes)
        return Set((context.databaseRoots + [context.cacheRoot])
            .map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
            .sorted().joined(separator: "\0")
    }
}
