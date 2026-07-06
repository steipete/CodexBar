import Foundation

/// The four event kinds a trace records. `decision` events capture a full policy tick (the
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
}

/// One line of a JSONL adaptive-refresh trace. Field presence depends on `kind`: `decision`
/// records populate `menuAgeSeconds`, `lowPowerModeEnabled`, `thermalState`, `reason`, and
/// `delaySeconds`, plus the shadow-mode `codexActivitySeconds` / `claudeActivitySeconds` signals
/// when tracing sampled them; `timerAdvanced` records populate `previousScheduledAt`,
/// `candidateScheduledAt`, `reason`, and `delaySeconds`; `menuOpen` and `refreshCompleted` carry
/// only `kind` and `timestamp`.
public struct AdaptiveRefreshTraceRecord: Sendable, Codable, Equatable {
    public let kind: AdaptiveRefreshTraceEventKind
    public let timestamp: Date
    public let menuAgeSeconds: TimeInterval?
    public let lowPowerModeEnabled: Bool?
    public let thermalState: ReplayThermalState?
    public let reason: String?
    public let delaySeconds: TimeInterval?
    /// `timerAdvanced` only: the adaptive timer's scheduled refresh time before the advance, or
    /// `nil` when no refresh had been scheduled yet (matches
    /// `UsageStore.shouldAdvanceAdaptiveTimer`'s "always advance when nothing is scheduled" rule).
    public let previousScheduledAt: Date?
    /// `timerAdvanced` only: the refresh time the timer advanced to, i.e. the menu-open timestamp
    /// plus the freshly computed decision's delay.
    public let candidateScheduledAt: Date?
    /// `decision` only, and only while the `CodingActivityProbe` shadow-mode signal is being
    /// recorded: seconds since the newest local Codex session transcript was modified, or `nil`
    /// when unavailable. Record-only telemetry — never fed into `AdaptiveRefreshPolicy`. Optional
    /// so old trace lines without this field keep decoding (see `AdaptiveReplayTraceParserTests`).
    public let codexActivitySeconds: TimeInterval?
    /// `decision` only: the Claude Code counterpart of `codexActivitySeconds`.
    public let claudeActivitySeconds: TimeInterval?

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
        codexActivitySeconds: TimeInterval? = nil,
        claudeActivitySeconds: TimeInterval? = nil)
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
        self.codexActivitySeconds = codexActivitySeconds
        self.claudeActivitySeconds = claudeActivitySeconds
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
        claudeActivitySeconds: TimeInterval? = nil) -> Self
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
            claudeActivitySeconds: claudeActivitySeconds)
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
}
