import Foundation

/// Source progress lives in the existing file's scan_state, never in JSONL byte offsets.
struct OpenCodeSourceCheckpoint: Codable, Equatable, Sendable {
    static let currentVersion = 2
    var version = Self.currentVersion
    var sourcePath: String
    var fingerprint: Fingerprint
    var timeZoneIdentifier: String
    var sinceDay: String?
    var untilDay: String?
    var phase: Phase = .message
    var position = Cursor(timestamp: 0, rowID: Int64.max)
    var pendingPartContinuation: PartContinuation?
    var pendingParentCheck: ParentCheck?
    var skippedOversizedRow = false
    var rebuilding = false
    var hasUnknownTokens = false

    enum Phase: String, Codable, Sendable {
        case message
        case session_message
        case reconciliation
        case done
    }

    /// Rowid bounds raw work; the timestamp validates the revision of a resumed row.
    /// Reconciliation visits every raw row, so equal or regressing timestamps cannot hide updates.
    struct Cursor: Codable, Equatable, Sendable {
        var timestamp: Int64
        var rowID: Int64
    }

    struct Fingerprint: Codable, Equatable, Sendable {
        var path: String
        var size: Int64
        var modifiedUnixMs: Int64
        var walSize: Int64?
        var walModifiedUnixMs: Int64?
        var identity: String?
        var modifiedUnixNs: Int64?
        var walModifiedUnixNs: Int64?
    }

    struct PartContinuation: Codable, Equatable, Sendable {
        var message: OpenCodeLocalHistoryAdapter.Message
        var position = Cursor(timestamp: 0, rowID: 0)
        var hasValidParts = false
        var sessionFallback: OpenCodeLocalHistoryAdapter.Turn?
        var needsLegacyLookup = false
        var resumeValidated = true
    }

    struct ParentCheck: Codable, Equatable, Sendable {
        var rowIndex: Int64
        var parentID: String
    }

    var hasPendingWork: Bool {
        self.phase != .done
    }

    var isComplete: Bool {
        !self.hasPendingWork && !self.skippedOversizedRow
    }

    static func fresh(
        sourcePath: String,
        fingerprint: Fingerprint,
        calendar: Calendar = .current) -> Self
    {
        Self(sourcePath: sourcePath, fingerprint: fingerprint, timeZoneIdentifier: calendar.timeZone.identifier)
    }

    static func decode(_ payload: Data?) -> Self? {
        guard let payload,
              let value = try? JSONDecoder().decode(Self.self, from: payload),
              value.version == Self.currentVersion
        else { return nil }
        return value
    }
}
