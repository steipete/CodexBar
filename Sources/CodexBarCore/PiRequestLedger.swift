import Foundation

/// Pi input and cache categories are disjoint; the one-hour write category is a subset of writes.
struct PiRequestAccounting: Sendable, Equatable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let cacheWrite1hTokens: Int
    let totalTokens: Int
}

public struct PiRequestRecord: Codable, Sendable, Equatable {
    public var id: String
    public let timestampUnixMs: Int64
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let cacheWrite1hTokens: Int
    public let totalTokens: Int

    init(id: String, timestampUnixMs: Int64, accounting: PiRequestAccounting) {
        self.id = id
        self.timestampUnixMs = timestampUnixMs
        self.inputTokens = accounting.inputTokens
        self.outputTokens = accounting.outputTokens
        self.cacheReadTokens = accounting.cacheReadTokens
        self.cacheWriteTokens = accounting.cacheWriteTokens
        self.cacheWrite1hTokens = accounting.cacheWrite1hTokens
        self.totalTokens = accounting.totalTokens
    }
}

/// A bounded accounting-only export. Raw session and entry IDs never cross the transport boundary.
public struct PiRequestLedger: Codable, Sendable {
    // Provider-specific by design: Pi and OMP use one provider discriminator and identity namespace.
    public var schemaVersion = 2
    public var provider = "pi"
    public var startUnixMs: Int64
    public var endUnixMs: Int64
    public var records: [PiRequestRecord] = []
    public var conflictingIDs: [String] = []
    public var excludedCount = 0
    public var partial = false

    public func validate(startUnixMs: Int64, endUnixMs: Int64) throws {
        try self.validateEnvelope(startUnixMs: startUnixMs, endUnixMs: endUnixMs, recordCount: self.records.count)
        var total = 0
        for record in self.records {
            guard CodexRequestLedger.isDigest(record.id), (startUnixMs...endUnixMs).contains(record.timestampUnixMs),
                  [
                      record.inputTokens,
                      record.outputTokens,
                      record.cacheReadTokens,
                      record.cacheWriteTokens,
                      record.cacheWrite1hTokens,
                      record.totalTokens,
                  ].allSatisfy({ $0 >= 0 }),
                  record.cacheWrite1hTokens <= record.cacheWriteTokens,
                  let sum = CheckedSum.integers([
                      record.inputTokens, record.outputTokens, record.cacheReadTokens, record.cacheWriteTokens,
                  ]),
                  record.totalTokens >= sum
            else { throw RemoteCodexCostError.invalidReport }
            guard let sum = CheckedSum.integers([total, record.totalTokens]) else {
                throw RemoteCodexCostError.invalidReport
            }
            total = sum
        }
    }

    public static func load(
        startUnixMs: Int64,
        endUnixMs: Int64,
        processContexts: [PiSessionProcessContext] = []) async throws -> Self
    {
        try await CostUsageScanExecutor.run { checkCancellation in
            try PiSessionCostScanner.loadIdentified(
                startUnixMs: startUnixMs,
                endUnixMs: endUnixMs,
                options: .init(processContexts: processContexts),
                checkCancellation: checkCancellation)
        }
    }

    package static func makeMerger() -> @Sendable ([Self]) throws -> CodexRequestSubtotal {
        { try Self.merge($0) }
    }

    public static func merge(_ ledgers: [Self]) throws -> CodexRequestSubtotal {
        guard let first = ledgers.first else { throw RemoteCodexCostError.unavailable }
        var reducer = PiRequestReducer()
        var excluded = 0
        for ledger in ledgers {
            try ledger.validate(startUnixMs: first.startUnixMs, endUnixMs: first.endUnixMs)
            guard let count = CheckedSum.integers([excluded, ledger.excludedCount]) else {
                throw RemoteCodexCostError.invalidReport
            }
            excluded = count
            for id in ledger.conflictingIDs {
                reducer.reject(id)
            }
            for row in ledger.records {
                reducer.observe(row)
            }
        }
        return try self.subtotal(
            reducer: reducer,
            excluded: excluded,
            partial: ledgers.contains(where: \.partial))
    }

    private static func subtotal(
        reducer: PiRequestReducer, excluded: Int, partial: Bool) throws -> CodexRequestSubtotal
    {
        let conflicts = reducer.conflicts
        let accepted = reducer.records.values.filter { $0.totalTokens > 0 }
        guard let total = CheckedSum.integers(accepted.map(\.totalTokens)) else {
            throw RemoteCodexCostError.invalidReport
        }
        return .init(
            totalTokens: total,
            requestCount: accepted.count,
            conflictCount: conflicts.count,
            excludedCount: excluded,
            partial: partial || excluded > 0 || !conflicts.isEmpty,
            costUSD: nil,
            unpricedRequestCount: accepted.count)
    }
}

/// The same conservative reduction applies before file-final identity binding and across sources.
struct PiRequestReducer {
    var records: [String: PiRequestRecord] = [:]
    var conflicts = Set<String>()

    mutating func reject(_ id: String) {
        self.conflicts.insert(id)
        self.records.removeValue(forKey: id)
    }

    mutating func observe(_ row: PiRequestRecord) {
        guard !self.conflicts.contains(row.id) else { return }
        if let previous = self.records[row.id] {
            if previous != row {
                self.reject(row.id)
            }
        } else {
            self.records[row.id] = row
        }
    }

    /// Bound a single source while scanning; a union of validated sources has no cardinality cap.
    func checkSourceBounds() throws {
        guard self.records.count <= IdentifiedRequestLimits.maximumRecords,
              self.conflicts.count <= IdentifiedRequestLimits.maximumRecords
        else { throw RemoteCodexCostError.invalidReport }
    }
}
