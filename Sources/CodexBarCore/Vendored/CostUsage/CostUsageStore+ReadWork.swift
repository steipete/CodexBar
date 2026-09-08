import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

struct CostUsageStoreReadWorkMetrics: Codable, Equatable, Sendable {
    var fullSnapshotReads = 0
    var scannerSnapshotReads = 0
    var fileRows = 0
    var tokenSnapshotRows = 0
    var usageRows = 0
    var bufferedLines = 0
    var usagePayloadBytes = 0
    var bufferedPayloadBytes = 0
    var cacheConversions = 0
    var usageRowDecodeAttempts = 0
    var integrityChecks = 0
    var retryPresenceRows = 0
    var accumulatorRows = 0
    var readViewConversions = 0
    var readViewConversionsInTransaction = 0
    var aggregateGroupingRowVisits = 0
}

/// Opt-in diagnostic counters for one owned database; never installed in production.
final class CostUsageStoreReadWorkRecorder: @unchecked Sendable {
    let databaseURL: URL
    private let lock = NSLock()
    private var metrics = CostUsageStoreReadWorkMetrics()

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    func snapshot() -> CostUsageStoreReadWorkMetrics {
        self.lock.withLock { self.metrics }
    }

    func reset() {
        self.lock.withLock { self.metrics = CostUsageStoreReadWorkMetrics() }
    }

    func recordFullSnapshot() {
        self.lock.withLock { self.metrics.fullSnapshotReads += 1 }
    }

    func recordScannerSnapshot() {
        self.lock.withLock { self.metrics.scannerSnapshotReads += 1 }
    }

    func recordFile() {
        self.lock.withLock { self.metrics.fileRows += 1 }
    }

    func recordTokenSnapshot() {
        self.lock.withLock { self.metrics.tokenSnapshotRows += 1 }
    }

    func recordUsageRow(payloadBytes: Int) {
        self.lock.withLock {
            self.metrics.usageRows += 1
            self.metrics.usagePayloadBytes += payloadBytes
        }
    }

    func recordBufferedLine(payloadBytes: Int) {
        self.lock.withLock {
            self.metrics.bufferedLines += 1
            self.metrics.bufferedPayloadBytes += payloadBytes
        }
    }

    func recordRetryPresence() {
        self.lock.withLock { self.metrics.retryPresenceRows += 1 }
    }

    func recordAccumulator() {
        self.lock.withLock { self.metrics.accumulatorRows += 1 }
    }

    func recordCacheConversion() {
        self.lock.withLock { self.metrics.cacheConversions += 1 }
    }

    func recordReadViewConversion(database: OpaquePointer) {
        let transactionActive = sqlite3_get_autocommit(database) == 0
        self.lock.withLock {
            self.metrics.readViewConversions += 1
            if transactionActive {
                self.metrics.readViewConversionsInTransaction += 1
            }
        }
    }

    func recordUsageRowDecodes(count: Int) {
        self.lock.withLock { self.metrics.usageRowDecodeAttempts += count }
    }

    func recordIntegrityCheck() {
        self.lock.withLock { self.metrics.integrityChecks += 1 }
    }

    func recordAggregateGroupingRowVisit() {
        self.lock.withLock { self.metrics.aggregateGroupingRowVisits += 1 }
    }
}

extension CostUsageStore {
    private nonisolated static let readWorkRecorderLock = NSLock()
    private nonisolated(unsafe) static var installedReadWorkRecorder: CostUsageStoreReadWorkRecorder?

    nonisolated static var readWorkRecorderForTesting: CostUsageStoreReadWorkRecorder? {
        get { self.readWorkRecorderLock.withLock { self.installedReadWorkRecorder } }
        set { self.readWorkRecorderLock.withLock { self.installedReadWorkRecorder = newValue } }
    }

    var scopedReadWorkRecorderForTesting: CostUsageStoreReadWorkRecorder? {
        guard let recorder = Self.readWorkRecorderForTesting,
              recorder.databaseURL == self.databaseURL else { return nil }
        return recorder
    }
}
