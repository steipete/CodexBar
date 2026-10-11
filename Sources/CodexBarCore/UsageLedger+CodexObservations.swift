import Foundation

extension CostUsageScanner {
    /// Explicit exports observe owned request records before native replay/copy suppression.
    @TaskLocal static var codexLedgerRequestObserver: CodexLedgerRequestObserver?
}

/// Keeps only numeric payloads and hashed identities; normal native scans have no observer.
final class CodexLedgerRequestObserver: Sendable {
    private struct Payload: Equatable {
        let model: String
        let usage: CostUsageCodexTotals
    }

    private let sinceUnixMs: Int64
    private let untilUnixMs: Int64
    private let state = CostUsageScanExecutor.LockedState((payloads: [String: Payload](), conflicts: Set<String>()))

    init(since: Date, until: Date) {
        self.sinceUnixMs = Int64(since.timeIntervalSince1970 * 1000)
        self.untilUnixMs = Int64((until.timeIntervalSince1970 * 1000).rounded())
    }

    /// Native ownership and timestamp parsing happen before this callback; exact window bounds apply here.
    func observe(sessionID: String?, row: CostUsageScanner.CodexUsageRow) {
        guard let sessionID, let responseID = row.responseID, let timestamp = row.timestampUnixMs,
              timestamp >= self.sinceUnixMs, timestamp <= self.untilUnixMs
        else { return }
        // Provider-specific by design: Native Codex request identity combines rollout ownership and response ID.
        let id = UsageLedgerRecord.digest(["codex", "request", sessionID, responseID])
        let payload = Payload(
            model: CostUsagePricing.normalizeCodexModel(row.model),
            usage: .init(input: row.input, cached: row.cached, output: row.output, reasoning: row.reasoning))
        self.state.withLock { state in
            if let previous = state.payloads[id], previous != payload {
                state.conflicts.insert(id)
            } else {
                state.payloads[id] = payload
            }
        }
    }

    var conflictingRecordIDs: [String] {
        self.state.withLock { $0.conflicts.sorted() }
    }
}
