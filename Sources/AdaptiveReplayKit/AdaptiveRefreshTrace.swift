import Foundation

/// The event kinds a trace records. `decision` events capture a full policy tick (the
/// signals it saw plus what it chose). `menuOpen` and `refreshCompleted` capture the two
/// ground-truth events the replay engine anchors a simulation to, independent of any candidate
/// policy. `timerAdvanced` captures the one place live behavior *isn't* a plain tick loop: when
/// opening the menu makes `UsageStore.noteMenuOpened(at:)` pull the next adaptive refresh forward
/// (see `UsageStore.shouldAdvanceAdaptiveTimer(scheduledAt:candidate:)`). Recording it separately
/// from `decision` lets a trace answer "did an advance happen, and to when" without relying on
/// fragile inference from decision-timestamp gaps.
public enum AdaptiveRefreshTraceEventKind: String, Sendable, Codable {
    case decision
    case menuOpen
    case refreshCompleted
    case timerAdvanced
    /// Every live advance comparison, including the cases correctly rejected because the current
    /// timer was already earlier. This is distinct from counterfactual replay advances.
    case timerAdvanceEvaluated
}

/// One line of a JSONL adaptive-refresh trace. Field presence depends on `kind`: `decision`
/// records populate `menuAgeSeconds`, `lowPowerModeEnabled`, `thermalState`, `reason`, and
/// `delaySeconds`, plus optional activity observations supplied by the input trace
/// (`codexActivitySeconds`/`claudeActivitySeconds`, the seconds-since-newest-transcript fields,
/// and the per-file intensity fields alongside them); timer advance records populate
/// `previousScheduledAt`, `candidateScheduledAt`, `reason`, and `delaySeconds`; `menuOpen` and
/// `refreshCompleted` carry only `kind` and `timestamp`.
public struct AdaptiveRefreshTraceRecord: Sendable, Codable, Equatable {
    public let kind: AdaptiveRefreshTraceEventKind
    public let timestamp: Date
    public let menuAgeSeconds: TimeInterval?
    public let lowPowerModeEnabled: Bool?
    public let thermalState: ReplayThermalState?
    public let reason: String?
    public let delaySeconds: TimeInterval?
    /// Timer advance records only: the adaptive timer's scheduled refresh time before the
    /// comparison, or `nil` when no refresh had been scheduled yet (matches
    /// `UsageStore.shouldAdvanceAdaptiveTimer`'s "always advance when nothing is scheduled" rule).
    public let previousScheduledAt: Date?
    /// Timer advance records only: the candidate refresh time, i.e. the menu-open timestamp plus
    /// the freshly computed decision's delay.
    public let candidateScheduledAt: Date?
    /// `timerAdvanceEvaluated` only: whether the live schedule comparison accepted the candidate.
    public let timerAdvanceAccepted: Bool?
    /// `timerAdvanceEvaluated` only: `previousScheduledAt - candidateScheduledAt`, captured before
    /// whole-second ISO-8601 serialization. Positive means the candidate was earlier. Optional for
    /// compatibility with traces recorded before exact comparison deltas were added.
    public let scheduleLeadSeconds: TimeInterval?
    /// `timerAdvanceEvaluated` only: whether another refresh was in flight at comparison time.
    public let refreshInFlight: Bool?
    /// `decision` only: seconds since the newest observed Codex session transcript modification,
    /// or `nil` when unavailable. Optional so old trace lines without this field keep decoding.
    public let codexActivitySeconds: TimeInterval?
    /// `decision` only: the Claude Code counterpart of `codexActivitySeconds`.
    public let claudeActivitySeconds: TimeInterval?
    /// `decision` only: how long the newest Codex transcript has been
    /// growing (its mtime minus its creationDate), or `nil` when unavailable. Not a separate
    /// session-age field — age is `codexActivitySeconds` + `codexSessionDurationSeconds`.
    public let codexSessionDurationSeconds: TimeInterval?
    /// `decision` only: the Claude Code counterpart of `codexSessionDurationSeconds`.
    public let claudeSessionDurationSeconds: TimeInterval?
    /// `decision` only: size in bytes of the newest Codex transcript, as a stateless raw value.
    public let codexTranscriptBytes: Int64?
    /// `decision` only: the Claude Code counterpart of `codexTranscriptBytes`.
    public let claudeTranscriptBytes: Int64?
    /// `decision` only: count of Codex `.jsonl` transcripts modified in the observation window.
    public let codexActiveTranscriptCount: Int?
    /// `decision` only: the Claude Code counterpart of `codexActiveTranscriptCount`.
    public let claudeActiveTranscriptCount: Int?

    public init(
        kind: AdaptiveRefreshTraceEventKind,
        timestamp: Date,
        menuAgeSeconds: TimeInterval? = nil,
        lowPowerModeEnabled: Bool? = nil,
        thermalState: ReplayThermalState? = nil,
        reason: String? = nil,
        delaySeconds: TimeInterval? = nil,
        previousScheduledAt: Date? = nil,
        candidateScheduledAt: Date? = nil,
        timerAdvanceAccepted: Bool? = nil,
        scheduleLeadSeconds: TimeInterval? = nil,
        refreshInFlight: Bool? = nil,
        codexActivitySeconds: TimeInterval? = nil,
        claudeActivitySeconds: TimeInterval? = nil,
        codexSessionDurationSeconds: TimeInterval? = nil,
        claudeSessionDurationSeconds: TimeInterval? = nil,
        codexTranscriptBytes: Int64? = nil,
        claudeTranscriptBytes: Int64? = nil,
        codexActiveTranscriptCount: Int? = nil,
        claudeActiveTranscriptCount: Int? = nil)
    {
        self.kind = kind
        self.timestamp = timestamp
        self.menuAgeSeconds = menuAgeSeconds
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.thermalState = thermalState
        self.reason = reason
        self.delaySeconds = delaySeconds
        self.previousScheduledAt = previousScheduledAt
        self.candidateScheduledAt = candidateScheduledAt
        self.timerAdvanceAccepted = timerAdvanceAccepted
        self.scheduleLeadSeconds = scheduleLeadSeconds
        self.refreshInFlight = refreshInFlight
        self.codexActivitySeconds = codexActivitySeconds
        self.claudeActivitySeconds = claudeActivitySeconds
        self.codexSessionDurationSeconds = codexSessionDurationSeconds
        self.claudeSessionDurationSeconds = claudeSessionDurationSeconds
        self.codexTranscriptBytes = codexTranscriptBytes
        self.claudeTranscriptBytes = claudeTranscriptBytes
        self.codexActiveTranscriptCount = codexActiveTranscriptCount
        self.claudeActiveTranscriptCount = claudeActiveTranscriptCount
    }

    // swiftlint:disable:next function_parameter_count
    public static func decision(
        timestamp: Date,
        menuAgeSeconds: TimeInterval?,
        lowPowerModeEnabled: Bool,
        thermalState: ReplayThermalState,
        reason: String,
        delaySeconds: TimeInterval,
        codexActivitySeconds: TimeInterval? = nil,
        claudeActivitySeconds: TimeInterval? = nil,
        codexSessionDurationSeconds: TimeInterval? = nil,
        claudeSessionDurationSeconds: TimeInterval? = nil,
        codexTranscriptBytes: Int64? = nil,
        claudeTranscriptBytes: Int64? = nil,
        codexActiveTranscriptCount: Int? = nil,
        claudeActiveTranscriptCount: Int? = nil) -> Self
    {
        Self(
            kind: .decision,
            timestamp: timestamp,
            menuAgeSeconds: menuAgeSeconds,
            lowPowerModeEnabled: lowPowerModeEnabled,
            thermalState: thermalState,
            reason: reason,
            delaySeconds: delaySeconds,
            codexActivitySeconds: codexActivitySeconds,
            claudeActivitySeconds: claudeActivitySeconds,
            codexSessionDurationSeconds: codexSessionDurationSeconds,
            claudeSessionDurationSeconds: claudeSessionDurationSeconds,
            codexTranscriptBytes: codexTranscriptBytes,
            claudeTranscriptBytes: claudeTranscriptBytes,
            codexActiveTranscriptCount: codexActiveTranscriptCount,
            claudeActiveTranscriptCount: claudeActiveTranscriptCount)
    }

    public static func menuOpen(timestamp: Date) -> Self {
        Self(kind: .menuOpen, timestamp: timestamp)
    }

    public static func refreshCompleted(timestamp: Date) -> Self {
        Self(kind: .refreshCompleted, timestamp: timestamp)
    }

    /// - Parameters:
    ///   - timestamp: When the menu open that triggered the advance occurred.
    ///   - previousScheduledAt: The timer's scheduled refresh time immediately before the advance.
    ///   - candidateScheduledAt: The refresh time the timer advanced to (`timestamp + delaySeconds`).
    ///   - reason: The freshly computed decision's reason (e.g. `"recentInteraction"`).
    ///   - delaySeconds: The freshly computed decision's delay.
    public static func timerAdvanced(
        timestamp: Date,
        previousScheduledAt: Date?,
        candidateScheduledAt: Date,
        reason: String,
        delaySeconds: TimeInterval) -> Self
    {
        Self(
            kind: .timerAdvanced,
            timestamp: timestamp,
            reason: reason,
            delaySeconds: delaySeconds,
            previousScheduledAt: previousScheduledAt,
            candidateScheduledAt: candidateScheduledAt)
    }

    // swiftlint:disable:next function_parameter_count
    public static func timerAdvanceEvaluated(
        timestamp: Date,
        previousScheduledAt: Date?,
        candidateScheduledAt: Date,
        reason: String,
        delaySeconds: TimeInterval,
        accepted: Bool,
        refreshInFlight: Bool) -> Self
    {
        Self(
            kind: .timerAdvanceEvaluated,
            timestamp: timestamp,
            reason: reason,
            delaySeconds: delaySeconds,
            previousScheduledAt: previousScheduledAt,
            candidateScheduledAt: candidateScheduledAt,
            timerAdvanceAccepted: accepted,
            scheduleLeadSeconds: previousScheduledAt.map { $0.timeIntervalSince(candidateScheduledAt) },
            refreshInFlight: refreshInFlight)
    }
}
