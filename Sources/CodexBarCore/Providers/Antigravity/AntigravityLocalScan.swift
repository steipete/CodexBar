import Foundation

extension AntigravityLocalReader {
    struct Context: Sendable {
        let home: URL
        let environment: [String: String]

        init(environment: [String: String]) {
            self.environment = environment
            self.home = environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser
        }

        var databaseRoots: [URL] {
            let app = AntigravityOfflineStore.appDataDirectory(home: self.home, env: self.environment)
            return [
                AntigravityOfflineStore.conversationsDirectory(home: self.home, env: self.environment),
                app,
                app.appendingPathComponent("conversations", isDirectory: true),
            ]
        }

        var cacheRoot: URL {
            let config = self.environment["TOKSCALE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? self.home.appendingPathComponent(".config/tokscale", isDirectory: true)
            return config.appendingPathComponent("antigravity-cache/sessions", isDirectory: true)
        }
    }

    struct Limits: Sendable {
        var databases = 500
        var directoryEntries = 10000
        var rowsPerDatabase = 10000
        var rows = 50000
        var blobBytes = 16 * 1024 * 1024
        var databaseBytes = 64 * 1024 * 1024
        var bytes = 128 * 1024 * 1024
        var schemaEntries = 128
        var schemaColumns = 64
        var schemaBytes = 64 * 1024
        var duration: TimeInterval = 5
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
    }

    enum ScanFailure: Error {
        case exhausted
        case invalid
    }

    /// One budget belongs to one executor job, including discovery and fallback.
    final class Budget {
        let limits: Limits
        let cancellation: () throws -> Void
        let clock: () -> TimeInterval
        let started: TimeInterval
        var statistics = Statistics()

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
            guard self.clock() - self.started < self.limits.duration else { throw ScanFailure.exhausted }
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

        func chargeSchemaBytes(_ count: Int) throws {
            try self.check()
            let (attempted, overflow) = self.statistics.schemaBytes.addingReportingOverflow(count)
            self.statistics.schemaBytes = overflow ? Int.max : attempted
            guard !overflow, attempted <= self.limits.schemaBytes else { throw ScanFailure.exhausted }
        }
    }

    struct Discovery {
        var paths: [URL] = []
        var isComplete = true
    }

    static func discover(roots: [URL], extension suffix: String, budget: Budget) throws -> Discovery {
        var result = Discovery()
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
                includingPropertiesForKeys: [.isRegularFileKey],
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
                guard budget.statistics.directoryEntries <= budget.limits.directoryEntries else {
                    throw ScanFailure.exhausted
                }
                guard !url.lastPathComponent.hasPrefix("."), url.pathExtension.lowercased() == suffix else { continue }
                guard result.paths.count < budget.limits.databases else {
                    result.isComplete = false
                    return result
                }
                do {
                    let values = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey])
                    guard values.isRegularFile == true else {
                        result.isComplete = false
                        continue
                    }
                    result.paths.append(url)
                } catch {
                    result.isComplete = false
                }
            }
            if enumerationFailed { result.isComplete = false }
        }
        result.paths.sort { $0.path < $1.path }
        return result
    }
}
