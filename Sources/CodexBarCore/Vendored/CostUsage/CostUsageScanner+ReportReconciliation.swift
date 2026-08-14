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
        let persistedRows = usage.codexRows ?? []
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
                let rowStandard = reconciledModeTokens.standard?[day]?[model] ?? 0
                let rowPriority = reconciledModeTokens.priority?[day]?[model] ?? 0
                if rowStandard != max(0, persistedStandard ?? 0)
                    || rowPriority != max(0, persistedPriority ?? 0)
                {
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
        modelsDevCacheRoot: URL?) -> Set<CodexDayModelKey>
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
                modelsDevCacheRoot: modelsDevCacheRoot)
            return breakdown.hasIncompletePricing ? group : nil
        })
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
