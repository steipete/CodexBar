import Foundation

extension CostUsageScanner {
    static func codexUsageRowKey(
        sessionId: String?,
        fileIdentity: String? = nil,
        row: CodexUsageRow) -> String
    {
        if let responseID = row.responseID {
            return self.codexResponseKey(scope: sessionId ?? fileIdentity ?? "", responseID: responseID)
        }
        return [
            sessionId.map { "session:\($0)" } ?? "file:\(fileIdentity ?? "")",
            row.turnID ?? "",
            row.eventIndex.map(String.init) ?? "",
            row.day,
            row.model,
            String(row.input),
            String(row.cached),
            String(row.output),
        ].joined(separator: "\u{1F}")
    }

    static func uniqueCodexRows(
        rows: [CodexUsageRow],
        sessionId: String?,
        fileIdentity: String,
        state: inout CodexScanState) -> [CodexUsageRow]
    {
        var unique: [CodexUsageRow] = []
        var acceptedKeys = Set<String>()
        for row in rows {
            let key = Self.codexCrossFileRowKey(sessionId: sessionId, fileIdentity: fileIdentity, row: row)
            if !state.seenCodexUsageRowKeys.contains(key), row.responseID == nil || !acceptedKeys.contains(key) {
                unique.append(row)
                acceptedKeys.insert(key)
            }
        }
        state.seenCodexUsageRowKeys.formUnion(acceptedKeys)
        return unique
    }

    static func rememberCodexRows(
        _ rows: [CodexUsageRow],
        sessionId: String?,
        fileIdentity: String,
        state: inout CodexScanState)
    {
        for row in rows {
            state.seenCodexUsageRowKeys.insert(self.codexCrossFileRowKey(
                sessionId: sessionId,
                fileIdentity: fileIdentity,
                row: row))
        }
    }

    /// Reconcile both scan orders against responses that actually contributed a row.
    static func reconcileCodexRequestMirrors(cache: inout CostUsageCache, context: CodexFileScanContext) {
        var aliases: [String: String] = [:]
        var owned: [String: (path: String, index: Int)] = [:]
        for (path, file) in cache.files where file.hasCurrentCodexParser {
            guard let mirrors = file.codexRequestLedgerState?.mirroredResponses, !mirrors.isEmpty else { continue }
            let scope = file.sessionId ?? path
            for (snapshot, responseID) in mirrors {
                aliases[scope + "\u{1F}" + snapshot] = Self.codexResponseKey(scope: scope, responseID: responseID)
            }
            for (index, row) in (file.codexRows ?? []).enumerated() where row.responseID != nil {
                owned[Self.codexUsageRowKey(sessionId: file.sessionId, fileIdentity: path, row: row)] = (path, index)
            }
        }
        guard !aliases.isEmpty, !owned.isEmpty else { return }
        var replacements: [String: [CodexUsageRow]] = [:]
        var removals: [String: Set<Int>] = [:]
        for (path, file) in cache.files where file.hasCurrentCodexParser {
            let scope = file.sessionId ?? path
            let rows = file.codexRows ?? []
            for (index, row) in rows.enumerated() {
                guard row.responseID == nil,
                      CostUsageDayRange.isInRange(
                          dayKey: row.day, since: context.range.scanSinceKey, until: context.range.scanUntilKey),
                      let match = (row.requestMirrorKeys ?? []).compactMap({ aliases[scope + "\u{1F}" + $0] })
                          .compactMap({ owned[$0] }).first
                else { continue }
                removals[path, default: []].insert(index)
                var targets = replacements[match.path] ?? cache.files[match.path]?.codexRows ?? []
                let target = targets[match.index]
                if target.model == row.model, target.knownCostNanos == nil, target.unpricedTokens == nil,
                   row.knownCostNanos != nil || row.unpricedTokens != nil
                   || row.pricingMode == "priority" || row.pricingMode == "ultrafast"
                   || (row.pricingModel != nil && row.pricingModel != row.model)
                {
                    targets[match.index].knownCostNanos = row.knownCostNanos
                    targets[match.index].unpricedTokens = row.unpricedTokens
                    targets[match.index].pricingModel = row.pricingModel
                    targets[match.index].pricingMode = row.pricingMode
                    replacements[match.path] = targets
                }
            }
        }
        for path in Set(replacements.keys).union(removals.keys) {
            guard let old = cache.files[path] else { continue }
            let rows = (replacements[path] ?? old.codexRows ?? []).enumerated().compactMap { index, row in
                removals[path]?.contains(index) == true ? nil : row
            }
            let updated = Self.codexFileUsageByFilteringRows(old, rows: rows, context: context)
            Self.applyFileDays(cache: &cache, fileDays: old.days, sign: -1)
            cache.files[path] = updated
            Self.applyFileDays(cache: &cache, fileDays: updated.days, sign: 1)
        }
    }

    private static func codexResponseKey(scope: String, responseID: String) -> String {
        [scope, "response", responseID].joined(separator: "\u{1F}")
    }

    private static func codexCrossFileRowKey(
        sessionId: String?,
        fileIdentity: String,
        row: CodexUsageRow) -> String
    {
        // Page-local event indices restart; timestamps distinguish new requests from archived copies.
        let key = self.codexUsageRowKey(sessionId: sessionId, fileIdentity: fileIdentity, row: row)
        return row.responseID == nil ? key + "\u{1F}" + (row.timestampUnixMs.map(String.init) ?? "") : key
    }
}
