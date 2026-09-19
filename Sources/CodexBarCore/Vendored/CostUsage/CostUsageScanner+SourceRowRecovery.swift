import Foundation

extension CostUsageScanner {
    static func codexRowsWithRetainedPricing(
        _ rows: [CodexUsageRow],
        source: (
            pricing: [CodexSourcePricingKey: CodexPricingEvidence]?, offsets: [Int: Int64], target: Int64?),
        pendingPricing: inout [String: CodexPricingEvidence],
        sessionId: String?,
        priorityTurns: [String: CodexPriorityTurnMetadata]) -> [CodexUsageRow]
    {
        if let sourcePricing = source.pricing {
            return self.codexRowsWithSourceRecoveryPricing(
                rows,
                pricing: sourcePricing,
                priorityTurns: priorityTurns,
                sourceBoundary: (source.offsets, sourcePricing.isEmpty ? nil : source.target))
        }
        return Self.codexRowsWithPricingMetadata(
            rows,
            priorityTurns: priorityTurns,
            preservingPricingFrom: { pendingPricing.removeValue(forKey: Self.codexUsageRowKey(
                sessionId: sessionId, row: $0)) })
    }

    static func retainCodexSourcePricing(
        _ usage: inout CostUsageFileUsage,
        pricing: [CodexSourcePricingKey: CodexPricingEvidence]?,
        anchor: CostUsageCodexTokenIndexAnchor?)
    {
        usage.codexPendingSourcePricing = usage.codexScanComplete == true
            && !usage.hasBufferedCodexForkRetryLines ? nil : pricing
        usage.codexPendingSourcePricingAnchor = usage.codexPendingSourcePricing == nil ? nil : anchor
    }

    static func codexSourcePricingForScan(
        cached: CostUsageFileUsage?,
        metadata: CodexFileMetadata,
        range: CostUsageDayRange,
        recoveringSourceRows: Bool) -> [CodexSourcePricingKey: CodexPricingEvidence]?
    {
        guard let cached else { return nil }
        let pricing = recoveringSourceRows
            ? Self.codexSourceRowRecoveryPricing(cached, range: range) ?? [:]
            : cached.codexPendingSourcePricing
        guard let pricing else { return nil }
        if pricing.isEmpty { return [:] }
        // A same-session replacement can contain identical requests with different historical pricing.
        // Keep an empty recovery map so an invalidated source stays unpriced through subsequent slices.
        let sourceAnchor = recoveringSourceRows ? cached.codexTokenIndexAnchor : cached.codexPendingSourcePricingAnchor
        guard cached.codexScanFileId != nil, cached.codexScanFileId == metadata.fileId,
              metadata.size >= cached.size,
              let sourceAnchor,
              sourceAnchor.indexedBytes <= (cached.codexScanTargetSize ?? cached.size),
              !recoveringSourceRows || sourceAnchor.indexedBytes == cached.size,
              Self.codexTokenIndexAnchorMatches(
                  sourceAnchor, fileURL: URL(fileURLWithPath: metadata.path), metadata: metadata)
        else { return [:] }
        // Larger append-only logs use bounded anchors. A same-size rewrite outside those windows
        // cannot be distinguished from a touch, so retain no historical pricing in that case.
        if metadata.size == cached.size, metadata.mtimeUnixMs != cached.mtimeUnixMs,
           sourceAnchor.windowStart > 0 { return [:] }
        let parsedBytes = cached.parsedBytes ?? 0
        if recoveringSourceRows || parsedBytes == 0 { return pricing }
        guard let anchor = cached.codexTokenIndexAnchor, anchor.indexedBytes == parsedBytes,
              Self.codexTokenIndexAnchorMatches(
                  anchor,
                  fileURL: URL(fileURLWithPath: metadata.path),
                  metadata: metadata)
        else { return [:] }
        return pricing
    }

    static func parseCodexRescan(
        input: CodexFileScanInput,
        context: CodexFileScanContext,
        recoveringSourceRows: Bool,
        preservingSourcePricing: Bool,
        maxBytesToRead: Int64?) throws -> CodexParseResult
    {
        let frozenTarget = preservingSourcePricing
            ? recoveringSourceRows ? input.cached?.size : input.cached?.codexPendingSourcePricingAnchor?.indexedBytes
            : nil
        return try parseCodexFileCancellable(
            fileURL: input.fileURL,
            range: context.range,
            scanTargetSize: min(frozenTarget ?? input.metadata.size, input.metadata.size),
            maxBytesToRead: maxBytesToRead,
            shouldStopReading: context.scanBudget.map { budget in
                { bytesRead in budget.shouldYield(additionalBytes: bytesRead) }
            },
            inheritedTotalsResolver: context.resources.inheritedResolver.inheritedTotals(for:atOrBefore:),
            checkCancellation: context.checkCancellation)
    }

    static func codexRescanSessionMetadata(
        cached: CostUsageFileUsage?,
        parsed: CostUsageCodexSessionMetadata) -> CostUsageCodexSessionMetadata
    {
        let metadata = cached?.codexSession ?? CostUsageCodexSessionMetadata(
            sessionId: cached?.sessionId,
            forkedFromId: cached?.forkedFromId,
            cwd: nil,
            title: nil,
            startedAtUnixMs: nil,
            latestActivityUnixMs: nil)
        return metadata.merging(parsed)
    }

    static func codexRescanPendingPricing(
        migratedCached: CostUsageFileUsage?,
        metadata: CodexFileMetadata,
        sessionId: String?,
        preserveCachedRows: Bool) -> [String: CodexPricingEvidence]
    {
        // Trace pruning must not erase observed pricing for an unchanged request.
        var pendingPricing: [String: CodexPricingEvidence] = if let cached = migratedCached,
                                                                cached.codexScanFileId != nil,
                                                                cached.codexScanFileId == metadata.fileId,
                                                                cached.sessionId == sessionId
        {
            cached.codexPendingPricing ?? [:]
        } else {
            [:]
        }
        for row in preserveCachedRows ? migratedCached?.codexRows ?? [] : [] {
            pendingPricing[Self.codexUsageRowKey(sessionId: migratedCached?.sessionId, row: row)] =
                CodexPricingEvidence(pricingModel: row.pricingModel, pricingMode: row.pricingMode)
        }
        return pendingPricing
    }

    static func codexSourceRowRecoveryPathKeys(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        roots: [URL]) -> Set<String>
    {
        Set(cache.files.compactMap { path, usage in
            let url = URL(fileURLWithPath: path)
            guard Self.codexSourceRowRecoveryPricing(usage, range: range) != nil,
                  Self.isWithinCodexRoots(fileURL: url, roots: roots),
                  FileManager.default.isReadableFile(atPath: path)
            else { return nil }
            let metadata = Self.codexFileMetadata(fileURL: url)
            guard let identity = metadata.fileId, identity == usage.codexScanFileId,
                  metadata.size == usage.size, metadata.mtimeUnixMs == usage.mtimeUnixMs
            else { return nil }
            return Self.codexPathKey(url)
        })
    }

    /// Matches pricing only after the source parser has established the request sequence.
    /// Repeated source requests may share this key; it never determines their multiplicity.
    struct CodexSourcePricingKey: Codable, Hashable {
        let day: String
        let model: String
        let rawModel: String?
        let turnID: String
        let timestampUnixMs: Int64
        let input: Int
        let cached: Int
        let output: Int

        init?(_ row: CodexUsageRow) {
            guard let turnID = row.turnID, !turnID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let timestampUnixMs = row.timestampUnixMs,
                  row.input >= 0, row.cached >= 0, row.output >= 0
            else { return nil }
            self.day = row.day
            self.model = row.model
            self.rawModel = row.rawModel
            self.turnID = turnID
            self.timestampUnixMs = timestampUnixMs
            self.input = row.input
            self.cached = row.cached
            self.output = row.output
        }
    }

    static func codexSourceRowRecoveryPricing(
        _ usage: CostUsageFileUsage,
        range: CostUsageDayRange) -> [CodexSourcePricingKey: CodexPricingEvidence]?
    {
        guard usage.hasCurrentCodexParser,
              usage.codexScanComplete == true,
              usage.parsedBytes == usage.size,
              usage.codexTokenIndexAnchor?.indexedBytes == usage.size,
              usage.codexJSONLResumeState == nil,
              !usage.hasBufferedCodexForkRetryLines,
              usage.sessionId != nil,
              let rows = usage.codexRows, !rows.isEmpty,
              self.codexExcessPricingRowGroups(usage).contains(where: {
                  CostUsageDayRange.isInRange(dayKey: $0.day, since: range.scanSinceKey, until: range.scanUntilKey)
              })
        else { return nil }

        var pricing: [CodexSourcePricingKey: CodexPricingEvidence] = [:]
        for row in rows where CostUsageDayRange.isInRange(
            dayKey: row.day, since: range.scanSinceKey, until: range.scanUntilKey)
        {
            // Native JSONL cannot assign saved monetary amounts to repeated identical requests.
            // Keep the original evidence when replay would erase money or an existing unpriced marker.
            guard row.knownCostNanos == nil, row.unpricedTokens == nil,
                  let key = CodexSourcePricingKey(row),
                  let model = row.pricingModel, !model.isEmpty,
                  row.pricingMode == "standard" || row.pricingMode == "priority"
            else { return nil }
            let evidence = CodexPricingEvidence(pricingModel: model, pricingMode: row.pricingMode)
            if let previous = pricing[key], previous != evidence { return nil }
            pricing[key] = evidence
        }
        return pricing.isEmpty ? nil : pricing
    }

    static func codexRowsWithSourceRecoveryPricing(
        _ rows: [CodexUsageRow],
        pricing: [CodexSourcePricingKey: CodexPricingEvidence],
        priorityTurns: [String: CodexPriorityTurnMetadata],
        sourceBoundary: (offsets: [Int: Int64], target: Int64?)) -> [CodexUsageRow]
    {
        func isAppended(_ row: CodexUsageRow) -> Bool {
            guard let target = sourceBoundary.target, let index = row.eventIndex,
                  let offset = sourceBoundary.offsets[index] else { return false }
            return offset > target
        }
        func retainedPricing(_ row: CodexUsageRow) -> CodexPricingEvidence? {
            if let target = sourceBoundary.target {
                guard let index = row.eventIndex, let offset = sourceBoundary.offsets[index],
                      offset <= target else { return nil }
            }
            return CodexSourcePricingKey(row).flatMap { pricing[$0] }
        }
        let classified = rows.map { row in
            guard !isAppended(row), retainedPricing(row) == nil else { return row }
            let (tokens, overflow) = row.input.addingReportingOverflow(row.output)
            // Source proves the request, but absent historical pricing must not silently become standard.
            return CodexUsageRow(
                day: row.day,
                model: row.model,
                rawModel: row.rawModel,
                turnID: row.turnID,
                eventIndex: row.eventIndex,
                timestampUnixMs: row.timestampUnixMs,
                input: row.input,
                cached: row.cached,
                output: row.output,
                reasoning: row.reasoning,
                knownCostNanos: row.knownCostNanos,
                unpricedTokens: overflow ? Int.max : max(1, tokens),
                pricingModel: row.pricingModel,
                pricingMode: row.pricingMode)
        }
        return Self.codexRowsWithPricingMetadata(
            classified,
            priorityTurns: priorityTurns,
            preservingPricingFrom: retainedPricing)
    }
}
