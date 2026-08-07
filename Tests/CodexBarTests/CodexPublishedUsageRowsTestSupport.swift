import Foundation
@testable import CodexBarCore

/// Reads exactly the row prefix published by the JSON cache. Tests must not query the SQLite
/// table directly because it may legitimately be ahead of the published generation after a
/// crash. Inline rows remain supported for fixtures that model pre-sidecar caches.
enum CodexPublishedUsageRowsTestSupport {
    enum ReadError: Error {
        case missingReference
        case needsRebuild
        case temporarilyUnavailable
    }

    static func load(
        path: String,
        usage: CostUsageFileUsage,
        cacheRoot: URL,
        calendar: Calendar = .current) throws -> [CostUsageScanner.CodexUsageRow]
    {
        if let rows = usage.codexRows { return rows }
        guard let state = usage.codexUsageRowSidecarState else {
            if usage.days.isEmpty { return [] }
            throw ReadError.missingReference
        }
        guard let fileID = usage.codexScanFileId,
              let anchor = usage.codexTokenIndexAnchor
        else { throw ReadError.missingReference }

        let fileURL = URL(fileURLWithPath: path)
        let reference = CostUsageCodexUsageRowReference(
            source: CostUsageCodexUsageRowSource(
                path: CostUsageCodexUsageRowStore.sourcePath(for: fileURL),
                fileId: fileID,
                indexedBytes: usage.parsedBytes ?? usage.size,
                anchor: anchor,
                isComplete: usage.codexScanComplete != false,
                changeUnixNs: usage.codexScanChangeUnixNs,
                sessionId: usage.sessionId,
                forkedFromId: usage.forkedFromId,
                forkDependencyKey: usage.forkBaselineDependencyKey,
                producerKey: usage.codexUsageRowProducerKey
                    ?? CostUsageCacheIO.currentProducerKey(provider: .codex)
                    ?? "codex:unknown",
                timeZoneIdentifier: calendar.timeZone.identifier),
            state: state)
        switch CostUsageCodexUsageRowStore(cacheRoot: cacheRoot).load(reference) {
        case let .ready(records):
            return records.map(\.usageRow)
        case .needsRebuild:
            throw ReadError.needsRebuild
        case .temporarilyUnavailable:
            throw ReadError.temporarilyUnavailable
        }
    }
}
