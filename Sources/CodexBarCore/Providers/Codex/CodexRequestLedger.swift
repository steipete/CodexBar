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

    public let model: String?
    public let pricingMode: String?
    public let includedInPlan: Bool

    init(
        id: String,
        timestampUnixMs: Int64,
        inputTokens: Int,
        cacheReadTokens: Int,
        outputTokens: Int,
        reasoningTokens: Int?,
        model: String? = nil,
        pricingMode: String? = nil,
        includedInPlan: Bool = false)
    {
        self.id = id
        self.timestampUnixMs = timestampUnixMs
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.model = model
        self.pricingMode = pricingMode
        self.includedInPlan = includedInPlan
    }

    enum CodingKeys: String, CodingKey {
        case id, timestampUnixMs, inputTokens, cacheReadTokens, outputTokens, reasoningTokens
        case model, pricingMode, includedInPlan
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.timestampUnixMs, forKey: .timestampUnixMs)
        try container.encode(self.inputTokens, forKey: .inputTokens)
        try container.encode(self.cacheReadTokens, forKey: .cacheReadTokens)
        try container.encode(self.outputTokens, forKey: .outputTokens)
        try container.encode(self.reasoningTokens, forKey: .reasoningTokens)
        try container.encode(self.model, forKey: .model)
        try container.encode(self.pricingMode, forKey: .pricingMode)
        try container.encode(self.includedInPlan, forKey: .includedInPlan)
    }
}

/// One exact inclusive UTC window. This identifies requests, without claiming account-wide usage.
public struct CodexRequestLedger: Codable, Sendable {
    public static let maximumRecords = 50000
    public static let maximumOutputBytes = 32 * 1024 * 1024
    public var schemaVersion = 2
    public var provider = "codex"
    public var startUnixMs: Int64
    public var endUnixMs: Int64
    public var records: [CodexRequestRecord] = []
    public var conflictingIDs: [String] = []
    public var excludedCount = 0
    public var partial = false

    public func validate(startUnixMs: Int64, endUnixMs: Int64) throws {
        guard self.schemaVersion == 2, self.provider == "codex",
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
                  record.pricingMode.map({ ["standard", "priority"].contains($0) }) ?? true,
                  record.model.map({ !$0.isEmpty }) ?? true,
                  record.reasoningTokens.map({ (0...record.outputTokens).contains($0) }) ?? true,
                  !record.includedInPlan || CostUsageScanner.codexAutoReviewIsIncludedInPlan(
                      model: "codex-auto-review",
                      timestampUnixMs: record.timestampUnixMs,
                      hasCreatorAccount: true),
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
        environment: [String: String] = ProcessInfo.processInfo.environment,
        processName: String = ProcessInfo.processInfo.processName,
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
        let hasCustomSessionsRoot = if let sessionsRoot = options.codexSessionsRoot?
            .standardizedFileURL,
            sessionsRoot.lastPathComponent != "sessions"
        {
            // A custom session root does not identify a Codex home or its state database.
            true
        } else {
            false
        }
        var scopedOptions = options
        if !hasCustomSessionsRoot {
            let codexHome = options.codexSessionsRoot?.standardizedFileURL.deletingLastPathComponent()
                ?? CodexHomeScope.ambientHomeURL(env: environment)
            let sqliteHome = CodexThreadMetadataReader.sqliteHomeDirectory(
                codexHomeDirectory: codexHome,
                environment: environment,
                resolvedWorkingDirectory: nil)
            scopedOptions.codexSessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
            scopedOptions.codexTraceDatabaseURL = options.codexTraceDatabaseURL
                ?? CodexPriorityDatabasePath.defaultURL(
                    processName: processName,
                    environment: environment,
                    codexHome: { sqliteHome })
        }
        let priority = CostUsageScanner.resolveCodexPriorityTurns(
            databaseURL: scopedOptions.codexTraceDatabaseURL,
            sinceDayKey: range.scanSinceKey,
            untilDayKey: range.scanUntilKey)
        let roots = CostUsageScanner.codexSessionsRoots(options: scopedOptions)
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
                ownedRequestObserver: { observation, model, evidence in
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
                    let pricing = Self.pricingEvidence(
                        observation: observation,
                        timestampUnixMs: milliseconds,
                        model: model,
                        evidence: evidence,
                        trace: priority)
                    let row = CodexRequestRecord(
                        id: id,
                        timestampUnixMs: milliseconds,
                        inputTokens: usage.input,
                        cacheReadTokens: usage.cached,
                        outputTokens: usage.output,
                        reasoningTokens: usage.reasoning.map { min(max(0, $0), max(0, usage.output)) },
                        model: pricing.model,
                        pricingMode: pricing.mode,
                        includedInPlan: pricing.included)
                    if records.count < Self.maximumRecords || records[id] != nil || conflicts.contains(id) {
                        Self.reduce(row, records: &records, conflicts: &conflicts)
                        exceededLimit = exceededLimit || conflicts.count > Self.maximumRecords
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

    /// Accounting contradictions exclude an identity; pricing contradictions retain its usage forever unpriced.
    private static func reduce(
        _ row: CodexRequestRecord,
        records: inout [String: CodexRequestRecord],
        conflicts: inout Set<String>)
    {
        guard !conflicts.contains(row.id) else { return }
        guard let previous = records[row.id] else {
            records[row.id] = row
            return
        }
        guard previous.timestampUnixMs == row.timestampUnixMs,
              previous.inputTokens == row.inputTokens,
              previous.cacheReadTokens == row.cacheReadTokens,
              previous.outputTokens == row.outputTokens,
              previous.reasoningTokens == row.reasoningTokens
        else {
            conflicts.insert(row.id)
            records.removeValue(forKey: row.id)
            return
        }
        guard previous != row else { return }
        // This existing wire representation is absorbing, including after JSON export and another clean copy.
        records[row.id] = CodexRequestRecord(
            id: row.id,
            timestampUnixMs: row.timestampUnixMs,
            inputTokens: row.inputTokens,
            cacheReadTokens: row.cacheReadTokens,
            outputTokens: row.outputTokens,
            reasoningTokens: row.reasoningTokens)
    }

    /// Trace billing identity is evidence even when no rate exists for it.
    private static func pricingEvidence(
        observation: CostUsageScanner.CodexRequestUsageRecord,
        timestampUnixMs: Int64,
        model: String,
        evidence: CostUsageScanner.CodexRequestPricingEvidence,
        trace: CostUsageScanner.CodexPriorityTurnsResolution) -> (model: String?, mode: String?, included: Bool)
    {
        let turn = evidence.turnID.flatMap { trace.turns[$0] }
        let mismatchedThread = turn?.threadID.map { $0 != observation.threadID } ?? false
        let validatedTrace = trace.validationPending || mismatchedThread ? nil : turn
        // A turn trace retains only its latest model. Native per-request evidence survives step switching.
        // Auto-review names the qualification, so its actual billing model still comes from the trace.
        let requestModel = CostUsageScanner.codexModelEvidence(observation.model)
        let selectedModel = requestModel.flatMap { $0 == "codex-auto-review" ? nil : $0 }
            ?? validatedTrace?.model ?? model
        let ambiguousModel = requestModel == nil && model != "codex-auto-review"
            && !CostUsagePricing.isCodexUnattributedModel(model)
            && (validatedTrace?.model.map { $0 != model } ?? false)
        let billingModel = mismatchedThread || ambiguousModel
            || CostUsagePricing.isCodexUnattributedModel(selectedModel) ? nil : selectedModel
        let candidateMode = validatedTrace != nil || evidence.nativeTier == .priority ? "priority"
            : evidence.nativeTier == .standard ? "standard" : nil
        let mode = trace.validationPending || mismatchedThread || evidence.nativeTier == .unknown ? nil : candidateMode
        let included = CostUsageScanner.codexAutoReviewIsIncludedInPlan(
            model: model, timestampUnixMs: timestampUnixMs, hasCreatorAccount: evidence.hasCreatorAccount)
        return (billingModel, mode, included)
    }

    /// Both scan snapshots must bypass Foundation's per-URL resource-value cache.
    static func fileMetadata(_ file: URL) throws -> URLResourceValues {
        var refreshed = file
        refreshed.removeAllCachedResourceValues()
        return try refreshed.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    }

    /// Conflicts remain excluded even when a later source supplies a clean observation of the identity.
    public static func merge(_ ledgers: [Self]) throws -> CodexRequestSubtotal {
        try self.makeMerger()(ledgers)
    }

    /// Capture once so a multi-host collection cannot mix catalog or custom-rate revisions.
    package static func makeMerger() -> @Sendable ([Self]) throws -> CodexRequestSubtotal {
        let catalog = CostUsagePricing.modelsDevCatalog() ?? ModelsDevCatalog(providers: [:])
        let customPricing = CostUsagePricing.customPricingOverlay()
        return { try self.merge($0, catalog: catalog, customPricing: customPricing) }
    }

    /// Deterministic injection seam; a complete union uses one collector snapshot and resolver.
    static func merge(
        _ ledgers: [Self],
        catalog: ModelsDevCatalog,
        customPricing: CostUsageCustomPricing) throws -> CodexRequestSubtotal
    {
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
                Self.reduce(row, records: &records, conflicts: &conflicts)
            }
        }
        var total = 0
        let accepted = records.values.filter { !conflicts.contains($0.id) }.sorted { $0.id < $1.id }
        let resolver = CostUsagePricing.CodexResolver(catalog: catalog)
        var cost = 0.0
        var unpriced = 0
        for row in accepted {
            let sum = total.addingReportingOverflow(row.inputTokens + row.outputTokens)
            guard !sum.overflow else { throw RemoteCodexCostError.invalidReport }
            total = sum.partialValue
            if let price = Self.price(row, customPricing: customPricing, resolver: resolver),
               price.isFinite, price >= 0
            {
                cost += price
                guard cost.isFinite else { throw RemoteCodexCostError.invalidReport }
            } else {
                unpriced += 1
            }
        }
        return CodexRequestSubtotal(
            totalTokens: total,
            requestCount: accepted.count,
            conflictCount: conflicts.count,
            excludedCount: excluded,
            partial: excluded > 0 || !conflicts.isEmpty || ledgers.contains(where: \.partial),
            costUSD: unpriced == 0 ? cost : nil,
            unpricedRequestCount: unpriced)
    }

    private static func price(
        _ row: CodexRequestRecord,
        customPricing: CostUsageCustomPricing,
        resolver: CostUsagePricing.CodexResolver) -> Double?
    {
        if row.includedInPlan,
           customPricing.rates(
               providerID: CostUsagePricing.codexModelsDevProviderID,
               model: row.model ?? "codex-auto-review") == nil
        {
            return 0
        }
        guard let model = row.model, let mode = row.pricingMode else { return nil }
        let date = Date(timeIntervalSince1970: Double(row.timestampUnixMs) / 1000)
        if mode == "priority" {
            // Unlike ordinary reports, an unsupported Priority rate must remain unknown.
            return CostUsagePricing.codexPriorityCostUSD(
                model: model,
                inputTokens: row.inputTokens,
                cachedInputTokens: row.cacheReadTokens,
                outputTokens: row.outputTokens,
                pricingDate: date,
                customPricing: customPricing,
                pricingResolver: resolver)
        }
        return CostUsagePricing.codexCostUSD(
            model: model,
            inputTokens: row.inputTokens,
            cachedInputTokens: row.cacheReadTokens,
            outputTokens: row.outputTokens,
            pricingDate: date,
            customPricing: customPricing,
            pricingResolver: resolver)
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func digest(_ components: [String]) -> String {
        let framed = components.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// API-equivalent estimate over the accepted identified requests, not complete account spend.
public struct CodexRequestSubtotal: Codable, Sendable {
    public let kind = "identified-request-subtotal"
    public let totalTokens: Int
    public let requestCount: Int
    public let conflictCount: Int
    public let excludedCount: Int
    public let partial: Bool
    public let costUSD: Double?
    public let unpricedRequestCount: Int

    enum CodingKeys: String,
        CodingKey
    { case kind, totalTokens, requestCount, conflictCount, excludedCount, partial, costUSD,
           unpricedRequestCount
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.kind, forKey: .kind)
        try container.encode(self.totalTokens, forKey: .totalTokens)
        try container.encode(self.requestCount, forKey: .requestCount)
        try container.encode(self.conflictCount, forKey: .conflictCount)
        try container.encode(self.excludedCount, forKey: .excludedCount)
        try container.encode(self.partial, forKey: .partial)
        try container.encode(self.costUSD, forKey: .costUSD)
        try container.encode(self.unpricedRequestCount, forKey: .unpricedRequestCount)
    }
}
