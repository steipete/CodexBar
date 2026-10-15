import Crypto
import Foundation

/// A provider-owned request; input includes cached input, while reasoning is part of output.
public struct CodexRequestRecord: Codable, Sendable, Equatable {
    public let id: String
    public let timestampUnixMs: Int64
    public let inputTokens: Int
    public let cacheReadTokens: Int
    public let outputTokens: Int
    public let reasoningTokens: Int?

    var usage: [Int?] {
        [self.inputTokens, self.cacheReadTokens, self.outputTokens, self.reasoningTokens]
    }
}

/// One exact inclusive UTC window. This identifies requests, without claiming account-wide usage.
public struct CodexRequestLedger: Codable, Sendable {
    public static let maximumRecords = 50000
    public static let maximumOutputBytes = 32 * 1024 * 1024
    public var schemaVersion = 1
    public var provider = "codex"
    public var startUnixMs: Int64
    public var endUnixMs: Int64
    public var records: [CodexRequestRecord] = []
    public var conflictingIDs: [String] = []
    public var excludedCount = 0
    public var partial = false

    public func validate(startUnixMs: Int64, endUnixMs: Int64) throws {
        guard self.schemaVersion == 1, self.provider == "codex",
              self.startUnixMs == startUnixMs, self.endUnixMs == endUnixMs,
              startUnixMs >= 0, endUnixMs <= 253_402_300_799_999, endUnixMs >= startUnixMs,
              startUnixMs % 86_400_000 == 0, endUnixMs - startUnixMs < 365 * 86_400_000,
              self.records.count <= Self.maximumRecords, self.conflictingIDs.count <= Self.maximumRecords,
              self.excludedCount >= 0, Set(self.conflictingIDs).count == self.conflictingIDs.count,
              self.conflictingIDs.allSatisfy(Self.isDigest)
        else { throw RemoteCodexCostError.invalidReport }
        var total = 0
        for record in self.records {
            guard Self.isDigest(record.id), (startUnixMs...endUnixMs).contains(record.timestampUnixMs),
                  record.inputTokens >= 0, (0...record.inputTokens).contains(record.cacheReadTokens),
                  record.outputTokens >= 0,
                  record.reasoningTokens.map({ (0...record.outputTokens).contains($0) }) ?? true,
                  !record.inputTokens.addingReportingOverflow(record.outputTokens).overflow
            else { throw RemoteCodexCostError.invalidReport }
            let sum = total.addingReportingOverflow(record.inputTokens + record.outputTokens)
            guard !sum.overflow else { throw RemoteCodexCostError.invalidReport }
            total = sum.partialValue
        }
    }

    /// Full native parsing is read-only; the opt-in observer sees owned replays before native collapse.
    public static func load(startUnixMs: Int64, endUnixMs: Int64) async throws -> Self {
        try await CostUsageScanExecutor.run { checkCancellation in
            try Self.load(
                startUnixMs: startUnixMs,
                endUnixMs: endUnixMs,
                options: .init(),
                checkCancellation: checkCancellation)
        }
    }

    static func load(
        startUnixMs: Int64,
        endUnixMs: Int64,
        options: CostUsageScanner.Options,
        checkCancellation: @escaping CostUsageScanner.CancellationCheck) throws -> Self
    {
        var ledger = Self(startUnixMs: startUnixMs, endUnixMs: endUnixMs)
        try ledger.validate(startUnixMs: startUnixMs, endUnixMs: endUnixMs)
        try checkCancellation()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let range = CostUsageScanner.CostUsageDayRange(
            since: Date(timeIntervalSince1970: Double(startUnixMs) / 1000),
            until: Date(timeIntervalSince1970: Double(endUnixMs) / 1000),
            calendar: calendar)
        let roots = CostUsageScanner.codexSessionsRoots(options: options)
        var files: [URL] = []
        var foundRoot = false
        for root in roots {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory) else { continue }
            guard directory.boolValue, FileManager.default.isReadableFile(atPath: root.path) else {
                ledger.partial = true
                continue
            }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                errorHandler: { _, _ in ledger.partial = true; return false })
            else { ledger.partial = true; continue }
            foundRoot = true
            while let file = enumerator.nextObject() as? URL {
                try checkCancellation()
                if file.pathExtension == "jsonl" { files.append(file) }
            }
        }
        guard foundRoot else { throw RemoteCodexCostError.unavailable }
        let index = CostUsageScanner.CodexSessionFileIndex(
            files: files,
            roots: roots,
            checkCancellation: checkCancellation)
        let resolver = CostUsageScanner.CodexInheritedTotalsResolver(
            fileIndex: index,
            checkCancellation: checkCancellation)
        var records: [String: CodexRequestRecord] = [:]
        var conflicts = Set<String>()
        var exceededLimit = false
        func markConflict(_ id: String) {
            if conflicts.count < Self.maximumRecords || conflicts.contains(id) {
                conflicts.insert(id)
            } else { exceededLimit = true }
        }
        for file in files.sorted(by: { $0.path < $1.path }) {
            try checkCancellation()
            let before = try? Self.fileMetadata(file)
            let parsed = try CostUsageScanner.parseCodexFileCancellable(
                fileURL: file,
                range: range,
                inheritedTotalsResolver: resolver.inheritedTotals(for:atOrBefore:),
                ownedRequestObserver: { observation, model in
                    guard OpenCodexRouteDispatcher.countsTowardCodexSubscription(modelName: model) else { return }
                    guard let timestamp = CostUsageScanner.dateFromTimestamp(observation.timestamp) else {
                        ledger.partial = true
                        ledger.excludedCount += 1
                        return
                    }
                    let rawMilliseconds = (timestamp.timeIntervalSince1970 * 1000).rounded()
                    guard (Double(startUnixMs)...Double(endUnixMs)).contains(rawMilliseconds) else { return }
                    let milliseconds = Int64(rawMilliseconds)
                    let id = Self.digest(["codex", observation.threadID, observation.responseID])
                    let usage = observation.usage
                    let row = CodexRequestRecord(
                        id: id,
                        timestampUnixMs: milliseconds,
                        inputTokens: usage.input,
                        cacheReadTokens: usage.cached,
                        outputTokens: usage.output,
                        reasoningTokens: usage.reasoning.map { min(max(0, $0), max(0, usage.output)) })
                    if let previous = records[id], previous.usage != row.usage { markConflict(id) }
                    if records.count < Self.maximumRecords || records[id] != nil {
                        if records[id].map({ $0.timestampUnixMs > milliseconds }) ?? true { records[id] = row }
                    } else { exceededLimit = true }
                },
                rejectedRequestObserver: { observation in
                    if let timestamp = observation.timestamp.flatMap(CostUsageScanner.dateFromTimestamp) {
                        let milliseconds = (timestamp.timeIntervalSince1970 * 1000).rounded()
                        guard (Double(startUnixMs)...Double(endUnixMs)).contains(milliseconds) else { return }
                        if let responseID = observation.responseID {
                            markConflict(Self.digest(["codex", observation.threadID, responseID]))
                        }
                    }
                    ledger.partial = true
                    ledger.excludedCount += 1
                },
                scanIssueObserver: { ledger.partial = true },
                checkCancellation: checkCancellation)
            guard !exceededLimit else { throw RemoteCodexCostError.invalidReport }
            let after = try? Self.fileMetadata(file)
            ledger.excludedCount += parsed.rows.filter {
                $0.responseID == nil && $0.day >= range.sinceKey && $0.day <= range.untilKey
                    && ($0.timestampUnixMs.map { (startUnixMs...endUnixMs).contains($0) } ?? true)
                    && OpenCodexRouteDispatcher.countsTowardCodexSubscription(modelName: $0.model)
            }.count
            ledger.partial = ledger.partial || parsed.jsonlResumeState != nil
                || parsed.bufferedUnresolvedForkLines != nil || parsed.bufferedSubagentLines != nil
                || before?.fileSize == nil || parsed.parsedBytes != Int64(before?.fileSize ?? 0)
                || before?.fileSize != after?.fileSize || before?.contentModificationDate != after?
                .contentModificationDate
        }
        ledger.records = records.values.sorted { $0.id < $1.id }
        ledger.conflictingIDs = conflicts.sorted()
        ledger.partial = ledger.partial || ledger.excludedCount > 0 || !conflicts.isEmpty
        try ledger.validate(startUnixMs: startUnixMs, endUnixMs: endUnixMs)
        return ledger
    }

    /// Both scan snapshots must bypass Foundation's per-URL resource-value cache.
    static func fileMetadata(_ file: URL) throws -> URLResourceValues {
        var refreshed = file
        refreshed.removeAllCachedResourceValues()
        return try refreshed.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    }

    /// Conflicts remain excluded even when a later source supplies a clean observation of the identity.
    public static func merge(_ ledgers: [Self]) throws -> CodexRequestSubtotal {
        guard let first = ledgers.first else { throw RemoteCodexCostError.unavailable }
        var records: [String: CodexRequestRecord] = [:]
        var conflicts = Set<String>()
        var excluded = 0
        for ledger in ledgers {
            try ledger.validate(startUnixMs: first.startUnixMs, endUnixMs: first.endUnixMs)
            let count = excluded.addingReportingOverflow(ledger.excludedCount)
            guard !count.overflow else { throw RemoteCodexCostError.invalidReport }
            excluded = count.partialValue
            conflicts.formUnion(ledger.conflictingIDs)
            for row in ledger.records {
                if let previous = records[row.id], previous.usage != row.usage { conflicts.insert(row.id) }
                if records[row.id].map({ $0.timestampUnixMs > row.timestampUnixMs }) ?? true { records[row.id] = row }
            }
        }
        var total = 0
        let accepted = records.values.filter { !conflicts.contains($0.id) }
        for row in accepted {
            let sum = total.addingReportingOverflow(row.inputTokens + row.outputTokens)
            guard !sum.overflow else { throw RemoteCodexCostError.invalidReport }
            total = sum.partialValue
        }
        return CodexRequestSubtotal(
            totalTokens: total,
            requestCount: accepted.count,
            conflictCount: conflicts.count,
            excludedCount: excluded,
            partial: excluded > 0 || !conflicts.isEmpty || ledgers.contains(where: \.partial))
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func digest(_ components: [String]) -> String {
        let framed = components.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Numeric identified-request subtotal; pricing is deliberately unavailable in this first stage.
public struct CodexRequestSubtotal: Codable, Sendable {
    public let kind = "identified-request-subtotal"
    public let totalTokens: Int
    public let requestCount: Int
    public let conflictCount: Int
    public let excludedCount: Int
    public let partial: Bool
    public let costUSD: Double? = nil

    enum CodingKeys: String,
    CodingKey { case kind, totalTokens, requestCount, conflictCount, excludedCount, partial, costUSD }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.kind, forKey: .kind)
        try container.encode(self.totalTokens, forKey: .totalTokens)
        try container.encode(self.requestCount, forKey: .requestCount)
        try container.encode(self.conflictCount, forKey: .conflictCount)
        try container.encode(self.excludedCount, forKey: .excludedCount)
        try container.encode(self.partial, forKey: .partial)
        try container.encodeNil(forKey: .costUSD)
    }
}
