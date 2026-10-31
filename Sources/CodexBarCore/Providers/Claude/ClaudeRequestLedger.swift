import Foundation

public struct ClaudeRequestRecord: Codable, Sendable, Equatable {
    public enum AccountingState: String, Codable, Sendable { case snapshot, terminal, pending }
    public let id: String
    public var timestampUnixMs: Int64
    public var model: String?
    public var missingModel: Bool
    public let inputTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreationTokens: Int
    public let cacheCreationOneHourTokens: Int
    public var outputTokens: Int
    public var accountingState: AccountingState

    var fixed: [Int] {
        [
            self.inputTokens,
            self.cacheReadTokens,
            self.cacheCreationTokens,
            self.cacheCreationOneHourTokens,
        ]
    }

    var total: Int? {
        let values = [self.inputTokens, self.cacheReadTokens, self.cacheCreationTokens, self.outputTokens]
        guard values.allSatisfy({ $0 >= 0 }) else { return nil }
        return CheckedSum.integers(values)
    }
}

/// Accounting-only native Claude evidence. Pending estimates never supply authoritative usage or model data.
public struct ClaudeRequestLedger: IdentifiedRequestLedger {
    public static var providerName: String {
        "claude"
    }

    public static var supportedSchemaVersion: Int {
        1
    }

    public var schemaVersion = 1
    public var provider = "claude"
    public var startUnixMs: Int64
    public var endUnixMs: Int64
    public var records: [ClaudeRequestRecord] = []
    public var conflictingIDs: [String] = []
    public var excludedCount = 0
    public var partial = false

    public func validate(startUnixMs: Int64, endUnixMs: Int64) throws {
        // Reuse the exact shared window and digest contract.
        try CodexRequestLedger(startUnixMs: self.startUnixMs, endUnixMs: self.endUnixMs)
            .validate(startUnixMs: startUnixMs, endUnixMs: endUnixMs)
        guard self.schemaVersion == 1, self.provider == Self.providerName, self.excludedCount >= 0,
              self.records.count + self.conflictingIDs.count <= CodexRequestLedger.maximumRecords,
              Set(self.conflictingIDs).count == self.conflictingIDs.count,
              self.conflictingIDs.allSatisfy(CodexRequestLedger.isDigest)
        else { throw RemoteCodexCostError.invalidReport }
        for row in self.records {
            guard CodexRequestLedger.isDigest(row.id), (startUnixMs...endUnixMs).contains(row.timestampUnixMs),
                  row.total != nil, row.cacheCreationOneHourTokens >= 0,
                  row.cacheCreationOneHourTokens <= row.cacheCreationTokens,
                  row.model != nil || row.missingModel || row.accountingState == .pending,
                  row.model.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true
            else { throw RemoteCodexCostError.invalidReport }
            if row.accountingState == .pending {
                guard row.total == 0, row.model == nil, !row.missingModel else {
                    throw RemoteCodexCostError.invalidReport
                }
            }
        }
    }

    /// One reducer is used before file collapse and again across source exports.
    struct Reducer {
        var records: [String: ClaudeRequestRecord] = [:]
        var conflicts = Set<String>()
        var retainedBytes = 1024
        var exceeded = false

        mutating func reject(_ id: String) {
            guard !self.exceeded else { return }
            if let old = self.records.removeValue(forKey: id) { self.retainedBytes -= self.size(old) }
            if self.conflicts.insert(id).inserted { self.retainedBytes += 68 }
            self.checkBounds()
        }

        mutating func add(_ incoming: ClaudeRequestRecord) {
            guard !self.conflicts.contains(incoming.id), !self.exceeded else { return }
            var row = incoming
            if let old = self.records[row.id] {
                row.timestampUnixMs = min(old.timestampUnixMs, row.timestampUnixMs)
                if old.accountingState == .pending {
                    // Incoming evidence replaces only the estimate.
                } else if row.accountingState == .pending {
                    row = old
                    row.timestampUnixMs = min(old.timestampUnixMs, incoming.timestampUnixMs)
                } else {
                    let modelsAgree = old.model == nil || row.model == nil
                        || Array(old.model!.utf8) == Array(row.model!.utf8)
                    let oldExact = old.accountingState != .snapshot
                    let newExact = row.accountingState != .snapshot
                    let outputsAgree = oldExact && newExact ? old.outputTokens == row.outputTokens
                        : oldExact ? row.outputTokens <= old.outputTokens
                        : newExact ? old.outputTokens <= row.outputTokens : true
                    guard old.fixed == row.fixed, modelsAgree, outputsAgree else { self.reject(row.id); return }
                    row.model = old.model ?? row.model
                    row.missingModel = old.missingModel || row.missingModel
                    if oldExact || (!newExact && old.outputTokens > row.outputTokens) {
                        row.outputTokens = old.outputTokens
                        row.accountingState = old.accountingState
                    }
                }
                if row == old { return }
                self.retainedBytes -= self.size(old)
            }
            self.records[row.id] = row
            self.retainedBytes += self.size(row)
            self.checkBounds()
        }

        private func size(_ row: ClaudeRequestRecord) -> Int {
            ((try? JSONEncoder().encode(row).count) ?? CodexRequestLedger.maximumOutputBytes) + 1
        }

        mutating func checkBounds() {
            self.exceeded = self.exceeded || self.records.count + self.conflicts.count > CodexRequestLedger
                .maximumRecords
                || self.retainedBytes > CodexRequestLedger.maximumOutputBytes
        }
    }

    public static func load(startUnixMs: Int64, endUnixMs: Int64) async throws -> Self {
        try await CostUsageScanExecutor.run { check in
            try Self.load(startUnixMs: startUnixMs, endUnixMs: endUnixMs, options: .init(), checkCancellation: check)
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
        var readable = false
        let files = try CostUsageScanner.inventoryClaudeRoots(
            CostUsageScanner.defaultClaudeProjectsRoots(options: options),
            checkCancellation: checkCancellation,
            scanIssue: { ledger.partial = true },
            readableRoot: { readable = true })
        guard readable else { throw RemoteCodexCostError.unavailable }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let range = CostUsageScanner.CostUsageDayRange(
            since: Date(timeIntervalSince1970: Double(startUnixMs) / 1000),
            until: Date(timeIntervalSince1970: Double(endUnixMs) / 1000),
            calendar: calendar)
        let resolver = CostUsagePricing.ClaudeResolver(catalog: ModelsDevCatalog(providers: [:]))
        var reducer = Reducer()
        for path in files.keys.sorted() {
            try checkCancellation()
            let file = URL(fileURLWithPath: path)
            let before = try? CostUsageClaudeFileStamp.readIfPresent(at: file)
            let parsed = try CostUsageScanner.parseClaudeFileCancellable(
                fileURL: file,
                range: range,
                providerFilter: .excludeVertexAI,
                pricingResolver: resolver,
                observation: { accounting in
                    ledger.observe(accounting, reducer: &reducer)
                },
                retainRows: false,
                scanIssue: { ledger.partial = true },
                shouldStop: { reducer.exceeded },
                checkCancellation: checkCancellation)
            guard !reducer.exceeded else { throw RemoteCodexCostError.invalidReport }
            let after = try? CostUsageClaudeFileStamp.readIfPresent(at: file)
            if before == nil || before != after || parsed.parsedBytes != before?.size { ledger.partial = true }
        }
        ledger.records = reducer.records.values.sorted { $0.id < $1.id }
        ledger.conflictingIDs = reducer.conflicts.sorted()
        ledger.partial = ledger.partial || ledger.excludedCount > 0 || !reducer.conflicts.isEmpty
            || ledger.records.contains { $0.accountingState == .pending }
        try ledger.validate(startUnixMs: startUnixMs, endUnixMs: endUnixMs)
        return ledger
    }

    private mutating func observe(_ accounting: ClaudeAccountingObservation, reducer: inout Reducer) {
        guard let date = accounting.timestamp?.date else {
            self.partial = true; self.excludedCount += 1; return
        }
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        guard (Double(self.startUnixMs)...Double(self.endUnixMs)).contains(milliseconds) else { return }
        let identity = accounting.identity
        let request = identity.requestID
        let session = identity.sessionID
        func nonblank(_ value: String?) -> Bool {
            value.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        }
        guard let messageID = identity.messageID, nonblank(messageID),
              nonblank(request ?? session) else { self.excludedCount += 1; self.partial = true; return }
        let id = CodexRequestLedger.digest(request.map { ["claude", "request", messageID, $0] }
            ?? ["claude", "session", session!, messageID])
        guard let counts = accounting.identified, let state = accounting.accountingState else {
            reducer.reject(id); return
        }
        guard counts.total != 0 || state != .snapshot else { return }
        let pending = accounting.preliminary
        let model = accounting.model.flatMap { nonblank($0) ? $0 : nil }
        let row = ClaudeRequestRecord(
            id: id,
            timestampUnixMs: Int64(milliseconds),
            model: pending ? nil : model,
            missingModel: !pending && model == nil,
            inputTokens: pending ? 0 : counts.input,
            cacheReadTokens: pending ? 0 : counts.cacheRead,
            cacheCreationTokens: pending ? 0 : counts.cacheCreation,
            cacheCreationOneHourTokens: pending ? 0 : counts.cacheCreation1h,
            outputTokens: pending ? 0 : counts.output,
            accountingState: pending ? .pending : state)
        reducer.add(row)
    }

    /// Freeze once before collection; reuse for every incremental union, never producer prices.
    public static func makeMerger() -> ([Self]) throws -> CodexRequestSubtotal {
        let resolver = CostUsagePricing.ClaudeResolver(now: Date(), cacheRoot: nil)
        resolver.prepareCatalog()
        return { try Self.merge($0, resolver: resolver) }
    }

    static func merge(_ ledgers: [Self], resolver: CostUsagePricing.ClaudeResolver) throws -> CodexRequestSubtotal {
        guard let first = ledgers.first else { throw RemoteCodexCostError.unavailable }
        var reducer = Reducer()
        var excluded = 0
        for ledger in ledgers {
            try ledger.validate(startUnixMs: first.startUnixMs, endUnixMs: first.endUnixMs)
            let sum = excluded.addingReportingOverflow(ledger.excludedCount)
            guard !sum.overflow else { throw RemoteCodexCostError.invalidReport }
            excluded = sum.partialValue
            for id in ledger.conflictingIDs {
                reducer.reject(id)
            }
            for row in ledger.records {
                reducer.add(row)
            }
            guard !reducer.exceeded else { throw RemoteCodexCostError.invalidReport }
        }
        var tokens = 0
        var requests = 0
        var cost = 0.0
        var unpriced = 0
        for row in reducer.records.values.sorted(by: { $0.id < $1.id }) {
            if row.total == 0 {
                let sum = excluded.addingReportingOverflow(row.accountingState == .pending ? 1 : 0)
                guard !sum.overflow else { throw RemoteCodexCostError.invalidReport }
                excluded = sum.partialValue
                continue
            }
            let sum = tokens.addingReportingOverflow(row.total!)
            guard !sum.overflow else { throw RemoteCodexCostError.invalidReport }
            tokens = sum.partialValue
            requests += 1
            if let model = row.model, !row.missingModel,
               let price = resolver.costUSD(
                   model: model,
                   inputTokens: row.inputTokens,
                   cacheReadInputTokens: row.cacheReadTokens,
                   cacheCreationInputTokens: row.cacheCreationTokens,
                   cacheCreationInputTokens1h: row.cacheCreationOneHourTokens,
                   outputTokens: row.outputTokens,
                   pricingDate: Date(timeIntervalSince1970: Double(row.timestampUnixMs) / 1000)),
               price.isFinite, price >= 0
            {
                cost += price
                guard cost.isFinite else { throw RemoteCodexCostError.invalidReport }
            } else {
                unpriced += 1
            }
        }
        return CodexRequestSubtotal(
            totalTokens: tokens,
            requestCount: requests,
            conflictCount: reducer.conflicts.count,
            excludedCount: excluded,
            partial: excluded > 0 || !reducer.conflicts.isEmpty || ledgers.contains(where: \.partial),
            costUSD: unpriced == 0 ? cost : nil,
            unpricedRequestCount: unpriced)
    }
}
