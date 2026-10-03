import Foundation

extension CostUsageScanner {
    static func codexUsageRowKey(
        sessionId: String?,
        fileIdentity: String? = nil,
        row: CodexUsageRow) -> String
    {
        if let responseID = row.responseID {
            return [sessionId ?? fileIdentity ?? "", "response", responseID].joined(separator: "\u{1F}")
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
            let mirrorKeys = Self.codexRequestMirrorKeys(sessionId: sessionId, fileIdentity: fileIdentity, row: row)
            let oppositeMirrors = row.responseID == nil
                ? state.seenLedgerRequestMirrorKeys : state.seenLegacyRequestMirrorKeys
            if !state.seenCodexUsageRowKeys.contains(key), row.responseID == nil || !acceptedKeys.contains(key),
               oppositeMirrors.isDisjoint(with: mirrorKeys)
            {
                unique.append(row)
                acceptedKeys.insert(key)
                if row.responseID == nil {
                    state.seenLegacyRequestMirrorKeys.formUnion(mirrorKeys)
                } else {
                    state.seenLedgerRequestMirrorKeys.formUnion(mirrorKeys)
                }
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
            let mirrorKeys = self.codexRequestMirrorKeys(sessionId: sessionId, fileIdentity: fileIdentity, row: row)
            if row.responseID == nil {
                state.seenLegacyRequestMirrorKeys.formUnion(mirrorKeys)
            } else {
                state.seenLedgerRequestMirrorKeys.formUnion(mirrorKeys)
            }
        }
    }

    private static func codexRequestMirrorKeys(
        sessionId: String?, fileIdentity: String, row: CodexUsageRow) -> [String]
    {
        let scope = sessionId ?? fileIdentity
        return (row.requestMirrorKeys ?? []).map { scope + "\u{1F}" + $0 }
    }

    private static func codexCrossFileRowKey(
        sessionId: String?,
        fileIdentity: String,
        row: CodexUsageRow) -> String
    {
        // Page-local event indices restart; timestamps distinguish new requests from archived copies.
        if row.responseID != nil {
            return self.codexUsageRowKey(sessionId: sessionId, fileIdentity: fileIdentity, row: row)
        }
        return self.codexUsageRowKey(sessionId: sessionId, fileIdentity: fileIdentity, row: row)
            + "\u{1F}" + (row.timestampUnixMs.map(String.init) ?? "")
    }
}
