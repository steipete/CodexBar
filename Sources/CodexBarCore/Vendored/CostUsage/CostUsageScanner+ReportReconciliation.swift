import Foundation

extension CostUsageScanner {
    struct CodexDayModelKey: Hashable {
        let day: String
        let model: String
    }

    struct CodexCanonicalPricingRows {
        let rows: [CodexUsageRow]
        let unresolvedGroups: Set<CodexDayModelKey>
    }

    struct CodexPricingModeEvidence {
        let mismatchGroups: Set<CodexDayModelKey>
        let priorityGroups: Set<CodexDayModelKey>
    }

    static func codexCanonicalPricingRows(_ usage: CostUsageFileUsage) -> CodexCanonicalPricingRows {
        // Re-emitted copies of one token event only differ in positional bookkeeping
        // (`eventIndex`); the canonical packed totals they are reconciled against count the
        // event once. Drop copies whose removal lands exactly on those totals so the
        // comparison is event-for-event.
        let persistedRows = Self.deduplicatedCodexUsageRows(
            usage.codexRows ?? [],
            canonicalDays: usage.days)
        let rowsByGroup = Dictionary(grouping: persistedRows) {
            CodexDayModelKey(day: $0.day, model: $0.model)
        }
        var canonicalRows: [CodexUsageRow] = []
        var unresolvedGroups = Set<CodexDayModelKey>()

        for day in usage.days.keys.sorted() {
            guard let models = usage.days[day] else { continue }
            for model in models.keys.sorted() {
                let key = CodexDayModelKey(day: day, model: model)
                let packed = models[model] ?? []
                let target = CodexRowTokenTotals(
                    input: max(0, packed[safe: 0] ?? 0),
                    cached: max(0, packed[safe: 1] ?? 0),
                    output: max(0, packed[safe: 2] ?? 0))
                guard let rows = self.reconciledCodexPricingRows(
                    rowsByGroup[key] ?? [],
                    target: target)
                else {
                    unresolvedGroups.insert(key)
                    continue
                }
                canonicalRows.append(contentsOf: rows)
            }
        }

        return CodexCanonicalPricingRows(rows: canonicalRows, unresolvedGroups: unresolvedGroups)
    }

    static func codexPricingModeEvidence(
        usage: CostUsageFileUsage,
        reconciledRows: [CodexUsageRow],
        range: CostUsageDayRange,
        priorityTurns: [String: CodexPriorityTurnMetadata]) -> CodexPricingModeEvidence
    {
        let reconciledModeTokens = self.codexModeTokenMaps(
            rows: reconciledRows,
            range: range,
            priorityTurns: priorityTurns)
        // The persisted maps are derived from the rows' own `pricingMode`, while the report also
        // consults the trace database. A turn the trace reports as priority after its rows were
        // persisted as standard is a tier-classification difference, not a row-ownership problem,
        // so retention is judged against both splits and only a group that matches neither counts
        // as mismatched. A wrongly retained row set still fails both, because the persisted totals
        // are canonical for the file and neither classification changes how many tokens the rows carry.
        let retainedModeTokens = self.codexModeTokenMaps(
            rows: reconciledRows,
            range: range,
            priorityTurns: [:])
        var mismatchGroups = Set<CodexDayModelKey>()
        var priorityGroups = Set<CodexDayModelKey>()
        for (day, models) in usage.days {
            for (model, packed) in models {
                let persistedStandard = usage.codexStandardTokens?[day]?[model]
                let persistedPriority = usage.codexPriorityTokens?[day]?[model]
                guard persistedStandard != nil || persistedPriority != nil else { continue }
                let (persistedModeTotal, modeOverflow) = max(0, persistedStandard ?? 0)
                    .addingReportingOverflow(max(0, persistedPriority ?? 0))
                let (canonicalTotal, canonicalOverflow) = max(0, packed[safe: 0] ?? 0)
                    .addingReportingOverflow(max(0, packed[safe: 2] ?? 0))
                let key = CodexDayModelKey(day: day, model: model)
                guard !modeOverflow, !canonicalOverflow else {
                    mismatchGroups.insert(key)
                    continue
                }
                // Copied fork prefixes can stale these legacy maps too. Only a map that is
                // independently canonical for its file may constrain retained row ownership.
                guard persistedModeTotal == canonicalTotal else { continue }
                let expectedStandard = max(0, persistedStandard ?? 0)
                let expectedPriority = max(0, persistedPriority ?? 0)
                let matchesReconciled = (reconciledModeTokens.standard?[day]?[model] ?? 0) == expectedStandard
                    && (reconciledModeTokens.priority?[day]?[model] ?? 0) == expectedPriority
                let matchesRetained = (retainedModeTokens.standard?[day]?[model] ?? 0) == expectedStandard
                    && (retainedModeTokens.priority?[day]?[model] ?? 0) == expectedPriority
                if !matchesReconciled, !matchesRetained {
                    mismatchGroups.insert(key)
                }
            }
        }
        for (day, models) in usage.codexPriorityTokens ?? [:] {
            for (model, tokens) in models where tokens > 0 {
                priorityGroups.insert(CodexDayModelKey(day: day, model: model))
            }
        }
        for row in usage.codexRows ?? [] where row.pricingMode == "priority"
            || row.turnID.flatMap({ priorityTurns[$0] }) != nil
        {
            priorityGroups.insert(CodexDayModelKey(day: row.day, model: row.model))
        }
        return CodexPricingModeEvidence(mismatchGroups: mismatchGroups, priorityGroups: priorityGroups)
    }

    static func codexIncompletePricingEvidenceGroups(
        usage: CostUsageFileUsage,
        range: CostUsageDayRange,
        priorityTurns: [String: CodexPriorityTurnMetadata],
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?,
        customPricing: CostUsageCustomPricing? = nil,
        pricingResolver: CostUsagePricing.CodexResolver? = nil) -> Set<CodexDayModelKey>
    {
        let rowsByGroup = Dictionary(grouping: usage.codexRows ?? []) {
            CodexDayModelKey(day: $0.day, model: $0.model)
        }
        return Set(rowsByGroup.compactMap { group, rows in
            guard CostUsageDayRange.isInRange(
                dayKey: group.day,
                since: range.sinceKey,
                until: range.untilKey)
            else { return nil }
            let breakdown = self.codexRowCostBreakdown(
                rows: rows,
                priorityTurns: priorityTurns,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot,
                customPricing: customPricing,
                pricingResolver: pricingResolver)
            return breakdown.hasIncompletePricing ? group : nil
        })
    }

    /// Identity of the token event a row carries, ignoring positional bookkeeping.
    /// `eventIndex` is regenerated per scan, so a copy of one event re-emitted during an
    /// incremental or buffered replay shares only this content with the original row.
    static func codexUsageRowEventKey(_ row: CodexUsageRow) -> String {
        [
            row.turnID ?? "",
            row.day,
            row.model,
            row.rawModel ?? "",
            row.timestampUnixMs.map(String.init) ?? "",
            String(row.input),
            String(row.cached),
            String(row.output),
            String(row.reasoning ?? -1),
        ].joined(separator: "\u{1F}")
    }

    /// Drops re-emitted copies of token events, but only where a copy is provably
    /// redundant: a (day, model) group is deduplicated only when its rows exceed the
    /// file's canonical packed totals and the deduplicated rows sum to them exactly.
    /// Distinct events that happen to share content are already counted by the
    /// canonical totals, so removing a copy would undershoot and the group stays
    /// verbatim. Groups without canonical totals, or that cannot be reconciled
    /// exactly, are left untouched for fail-closed reconciliation to report.
    static func deduplicatedCodexUsageRows(
        _ rows: [CodexUsageRow],
        canonicalDays: [String: [String: [Int]]]) -> [CodexUsageRow]
    {
        var groupOrder: [CodexDayModelKey] = []
        var indicesByGroup: [CodexDayModelKey: [Int]] = [:]
        for (index, row) in rows.enumerated() {
            let key = CodexDayModelKey(day: row.day, model: row.model)
            if indicesByGroup[key] == nil { groupOrder.append(key) }
            indicesByGroup[key, default: []].append(index)
        }
        var dropped = Set<Int>()
        for key in groupOrder {
            guard let packed = canonicalDays[key.day]?[key.model],
                  let indices = indicesByGroup[key]
            else { continue }
            let target = CodexRowTokenTotals(
                input: max(0, packed[safe: 0] ?? 0),
                cached: max(0, packed[safe: 1] ?? 0),
                output: max(0, packed[safe: 2] ?? 0))
            var sum = CodexRowTokenTotals()
            guard indices.allSatisfy({ sum.add(rows[$0]) }), sum.exceeds(target) else { continue }

            var bestByEvent: [String: Int] = [:]
            for index in indices {
                let eventKey = Self.codexUsageRowEventKey(rows[index])
                guard let existing = bestByEvent[eventKey] else {
                    bestByEvent[eventKey] = index
                    continue
                }
                if Self.preferredCodexUsageRow(rows[index], over: rows[existing]) {
                    bestByEvent[eventKey] = index
                }
            }
            let kept = Set(bestByEvent.values)
            var deduplicatedSum = CodexRowTokenTotals()
            guard kept.count < indices.count,
                  kept.allSatisfy({ deduplicatedSum.add(rows[$0]) }),
                  deduplicatedSum == target
            else { continue }
            dropped.formUnion(indices.filter { !kept.contains($0) })
        }
        guard !dropped.isEmpty else { return rows }
        return rows.enumerated().compactMap { dropped.contains($0.offset) ? nil : $0.element }
    }

    private static func preferredCodexUsageRow(_ candidate: CodexUsageRow, over existing: CodexUsageRow) -> Bool {
        func pricingRank(_ row: CodexUsageRow) -> Int {
            (row.knownCostNanos != nil ? 4 : 0)
                + (row.pricingModel != nil ? 2 : 0)
                + (row.pricingMode != nil ? 1 : 0)
        }
        let candidateRank = pricingRank(candidate)
        let existingRank = pricingRank(existing)
        if candidateRank != existingRank {
            return candidateRank > existingRank
        }
        return (candidate.eventIndex ?? -1) > (existing.eventIndex ?? -1)
    }

    private struct CodexRowTokenTotals: Equatable {
        var input: Int = 0
        var cached: Int = 0
        var output: Int = 0

        mutating func add(_ row: CodexUsageRow) -> Bool {
            guard let input = Self.sum(self.input, max(0, row.input)),
                  let cached = Self.sum(self.cached, max(0, row.cached)),
                  let output = Self.sum(self.output, max(0, row.output))
            else { return false }
            self = CodexRowTokenTotals(input: input, cached: cached, output: output)
            return true
        }

        func exceeds(_ other: CodexRowTokenTotals) -> Bool {
            self.input > other.input || self.cached > other.cached || self.output > other.output
        }

        private static func sum(_ lhs: Int, _ rhs: Int) -> Int? {
            let (sum, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? nil : sum
        }
    }

    private static func reconciledCodexPricingRows(
        _ rows: [CodexUsageRow],
        target: CodexRowTokenTotals) -> [CodexUsageRow]?
    {
        var allRowsTotal = CodexRowTokenTotals()
        guard rows.allSatisfy({ allRowsTotal.add($0) }) else { return nil }
        if target == CodexRowTokenTotals() {
            return []
        }
        if allRowsTotal == target {
            let firstTokenRow = rows.firstIndex {
                $0.input > 0 || $0.cached > 0 || $0.output > 0
            }
            if let firstTokenRow,
               rows[..<firstTokenRow].contains(where: { ($0.knownCostNanos ?? 0) != 0 })
            {
                return nil
            }
            return rows
        }
        guard allRowsTotal.exceeds(target) else { return nil }

        var suffixTotal = CodexRowTokenTotals()
        for index in rows.indices.reversed() {
            guard suffixTotal.add(rows[index]) else { return nil }
            if suffixTotal == target {
                return Array(rows[index...])
            }
            if suffixTotal.exceeds(target) {
                return nil
            }
        }
        return nil
    }
}
