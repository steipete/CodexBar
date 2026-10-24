import Foundation

/// The OpenCode local history adapter's durable progress for the one registered source
/// file (`opencode.db`), persisted inside `CostUsageStoreScanState.resumePayload` when the
/// record discriminates to `opencodeLocalHistory` (#4752 point 1).
///
/// Versioned, typed, and JSON-only: it needs no SQL schema migration and never places
/// SQLite rowids in the byte-oriented fields (`parsed_bytes`, `scan_target_size`) that the
/// JSONL machinery owns. Native Codex records are untouched — the discriminator defaults
/// them to native and their `CostUsageJsonl.ResumeState` decodes exactly as before.
///
/// Checkpoint semantics (mirroring the #4752 adjustments):
/// - **Table windows** are `[low, high]` rowid ranges already represented in the store per
///   table (`message`, `part`, `session_message`). Boundaries pin with their owning
///   `SELECT`, never a later `MAX(rowid)` from a different snapshot (#4744 regression 3).
/// - **Updated watermarks** track `time_updated` progression per table so in-place
///   upstream mutation is picked up by bounded rechecks rather than assumed absent
///   (#4752 point 4).
/// - **Part continuation** checkpoints a strict `(messageRowid, partRowid)` pair so a
///   message with more parts than one pass's budget resumes mid-message instead of
///   restarting at its first part (#4744 regression 2). It must not advance until the
///   message's reevaluation is durably committed.
/// - **Reconciliation progress** keeps a resumable cursor for coverage verification
///   (settle/deletion sweeps) so it never becomes whole-history work per refresh
///   (#4752 point 5).
struct OpenCodeSourceCheckpoint: Codable, Equatable, Sendable {
    /// Payload schema version; decoders reject anything newer than they understand so an
    /// older build never misreads a newer checkpoint as complete.
    static let currentVersion = 1

    var version: Int
    /// Resolved source path (symlinks resolved). Compared with the registered record's
    /// path before any progress is trusted — a checkpoint never applies to another
    /// database (#3273 cache-source validation, carried).
    var sourcePath: String
    /// The identity capture the progress was proven against, taken before the owning
    /// pass's reads and verified after (WAL-aware, so WAL appends invalidate without a
    /// checkpoint-aware wait).
    var fingerprint: Fingerprint
    var tables: TableWindows
    /// In-flight `(messageRowid, partRowid)` continuation inside an oversized message's
    /// part stream; nil when no message is mid-flight.
    var pendingPartContinuation: PartContinuation?
    /// Resumable reconciliation (settle/deletion verification) progress; nil when idle.
    var reconciliation: ReconciliationProgress?

    struct Fingerprint: Codable, Equatable, Sendable {
        var path: String
        var size: Int64
        var modifiedUnixMs: Int64
        var walSize: Int64?
        var walModifiedUnixMs: Int64?
    }

    /// Per-table rowid windows `[low, high]`: `low == 0` means everything below is
    /// represented; `high` is the inclusive re-read boundary above. `TableWindows.updatedMs`
    /// fields hold each table's `time_updated` recheck watermark.
    struct TableWindows: Codable, Equatable, Sendable {
        var message: Window
        var part: Window
        var sessionMessage: Window
        var messageUpdatedMs: Int64
        var partUpdatedMs: Int64
        var sessionMessageUpdatedMs: Int64

        struct Window: Codable, Equatable, Sendable {
            var low: Int64
            var high: Int64

            static let empty = Self(low: 0, high: 0)
        }

        static let empty = Self(
            message: .empty,
            part: .empty,
            sessionMessage: .empty,
            messageUpdatedMs: 0,
            partUpdatedMs: 0,
            sessionMessageUpdatedMs: 0)
    }

    /// Strict continuation inside one message's parts: the message currently being
    /// re-evaluated and the highest part rowid durably represented for it.
    struct PartContinuation: Codable, Equatable, Sendable {
        var messageRowid: Int64
        var partRowid: Int64
    }

    /// Resumable coverage reconciliation: which table is being verified and up to which
    /// rowid. A pass never reports a date window complete until reconciliation can prove
    /// the omitted range cannot overlap it (#4752 point 7).
    struct ReconciliationProgress: Codable, Equatable, Sendable {
        var table: String
        var verifiedUpToRowid: Int64
    }

    /// A checkpoint for a database never ingested yet.
    static func fresh(sourcePath: String, fingerprint: Fingerprint) -> Self {
        Self(
            version: Self.currentVersion,
            sourcePath: sourcePath,
            fingerprint: fingerprint,
            tables: .empty,
            pendingPartContinuation: nil,
            reconciliation: nil)
    }

    /// Decodes the adapter checkpoint from a CodexBar store payload. Returns `nil` when the
    /// payload is absent, foreign (native Codex resume state), or ahead of this build —
    /// never a silently wrong progress.
    static func decode(_ payload: Data?) -> Self? {
        guard let payload,
              let decoded = try? JSONDecoder().decode(Self.self, from: payload),
              decoded.version <= Self.currentVersion
        else { return nil }
        return decoded
    }
}
