#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Stable sidecar identity for a normalized Codex rollout.
/// Scanner cursors are intentionally excluded: they do not alter the sidecar's
/// persisted usage, but rows, attribution, and cost maps do.
struct CodexWorkspaceUsageFingerprintPayload: Encodable {
    let days: [String: [String: [Int]]]
    let lastModel: String?
    let sessionID: String?
    let forkedFromID: String?
    let projectPath: String?
    let canonicalProjectPath: String?
    let session: CostUsageCodexSessionMetadata?
    let costNanos: [String: [String: Int64]]?
    let prioritySurchargeNanos: [String: [String: Int64]]?
    let standardCostNanos: [String: [String: Int64]]?
    let priorityCostNanos: [String: [String: Int64]]?
    let standardTokens: [String: [String: Int]]?
    let priorityTokens: [String: [String: Int]]?
    let rowSidecarContent: CodexWorkspaceUsageRowContentIdentity?
    let rows: [CostUsageScanner.CodexUsageRow]?

    init(usage: CostUsageFileUsage) {
        self.days = usage.days
        self.lastModel = usage.lastModel
        self.sessionID = usage.sessionId
        self.forkedFromID = usage.forkedFromId
        self.projectPath = usage.projectPath
        self.canonicalProjectPath = usage.canonicalProjectPath
        self.session = usage.codexSession
        self.costNanos = usage.codexCostNanos
        self.prioritySurchargeNanos = usage.codexPrioritySurchargeNanos
        self.standardCostNanos = usage.codexStandardCostNanos
        self.priorityCostNanos = usage.codexPriorityCostNanos
        self.standardTokens = usage.codexStandardTokens
        self.priorityTokens = usage.codexPriorityTokens
        self.rowSidecarContent = usage.codexUsageRowSidecarState.map(CodexWorkspaceUsageRowContentIdentity.init)
        // Legacy inline rows remain part of the identity until they are migrated. Sidecar-backed
        // entries use their compact, content-addressed published state instead of re-encoding the
        // entire historical prefix on every bounded refresh.
        self.rows = usage.codexUsageRowSidecarState == nil ? usage.codexRows : nil
    }
}

/// Semantic row identity only. Generation and parser cursors are deliberately excluded so a
/// zero-row suffix or crash-recovery republish does not force Workspace event replacement.
struct CodexWorkspaceUsageRowContentIdentity: Encodable {
    let rowCount: Int
    let prefixDigest: String
    let coverageSinceKey: String
    let coverageUntilKey: String
    let ownershipKey: String?
    let pricingKey: String
    let priorityMetadataKey: String

    init(_ state: CostUsageCodexUsageRowSidecarState) {
        self.rowCount = state.rowCount
        self.prefixDigest = state.prefixDigest
        self.coverageSinceKey = state.coverageSinceKey
        self.coverageUntilKey = state.coverageUntilKey
        self.ownershipKey = state.ownershipKey
        self.pricingKey = state.pricingKey
        self.priorityMetadataKey = state.priorityMetadataKey
    }
}

enum CodexWorkspaceUsageFingerprint {
    static func make(for usage: CostUsageFileUsage) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(CodexWorkspaceUsageFingerprintPayload(usage: usage)) else {
            return "unavailable"
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension CostUsageFileUsage {
    func codexWorkspaceUsageFingerprintValue() -> String {
        self.codexWorkspaceContentFingerprint ?? CodexWorkspaceUsageFingerprint.make(for: self)
    }

    func refreshingCodexWorkspaceUsageFingerprint() -> Self {
        var updated = self
        updated.codexWorkspaceContentFingerprint = CodexWorkspaceUsageFingerprint.make(for: updated)
        return updated
    }
}
