import AdaptiveReplayKit
import CodexBarCore
import Foundation

/// Opt-in trace recorder for the adaptive refresh replay harness. OFF by
/// default — gated on the `adaptiveRefreshTraceEnabled` defaults key, the same lightweight
/// `UserDefaults.standard.bool(forKey:)` pattern `debugDisableKeychainAccess` and
/// `debugMainThreadHangWatchdog` use for opt-in diagnostics, so enabling it is
/// `defaults write com.steipete.codexbar adaptiveRefreshTraceEnabled -bool true` with no UI
/// plumbing required for phase 1.
///
/// Writes to the app's Application Support directory using `AppGroupSupport.localFallbackDirectory`
/// — the same directory the widget snapshot fallback already uses — so trace files land next to
/// other CodexBar state instead of inventing a new location convention.
enum AdaptiveRefreshTraceRecording {
    static let defaultsKey = "adaptiveRefreshTraceEnabled"
    static let traceFilename = "adaptive-refresh-trace.jsonl"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: self.defaultsKey)
    }

    static func defaultTraceURL(fileManager: FileManager = .default) -> URL {
        AppGroupSupport.localFallbackDirectory(fileManager: fileManager)
            .appendingPathComponent(self.traceFilename, isDirectory: false)
    }

    private static let writer = AdaptiveRefreshTraceWriter(fileURL: Self.defaultTraceURL())

    #if DEBUG
    /// Redirects every `record*` call to a test-owned writer instead of the shared Application
    /// Support singleton above, so tests can assert on trace contents without touching real app
    /// state or racing other parallel tests that also enable tracing. `nil` (the default) uses the
    /// real `writer`. Instance-scoped per test via set/reset in a `defer`, mirroring
    /// `UsageStore.refreshTimerSleepOverrideForTesting`.
    nonisolated(unsafe) static var writerOverrideForTesting: AdaptiveRefreshTraceWriter?
    #endif

    private static var activeWriter: AdaptiveRefreshTraceWriter {
        #if DEBUG
        self.writerOverrideForTesting ?? self.writer
        #else
        self.writer
        #endif
    }

    /// - Parameter activitySample: the shadow-mode `CodingActivityProbe` reading for this tick, or
    ///   `nil` when the caller didn't sample one (e.g. tracing was disabled at sample time). Every
    ///   field on it is optional and independent, so a partial sample (say, Codex data but no
    ///   Claude data) still records whatever it has.
    static func recordDecision(
        now: Date,
        lastMenuOpenAt: Date?,
        lowPowerModeEnabled: Bool,
        thermalState: ProcessInfo.ThermalState,
        decision: AdaptiveRefreshPolicy.Decision,
        activitySample: CodingActivitySample? = nil)
    {
        guard self.isEnabled else { return }
        let menuAgeSeconds = lastMenuOpenAt.map { now.timeIntervalSince($0) }
        self.activeWriter.append(.decision(
            timestamp: now,
            menuAgeSeconds: menuAgeSeconds,
            lowPowerModeEnabled: lowPowerModeEnabled,
            thermalState: self.replayThermalState(for: thermalState),
            reason: decision.reason.rawValue,
            delaySeconds: TimeInterval(decision.delay.components.seconds),
            codexActivitySeconds: activitySample?.codexSecondsSinceActivity,
            claudeActivitySeconds: activitySample?.claudeSecondsSinceActivity,
            codexSessionDurationSeconds: activitySample?.codexSessionDurationSeconds,
            claudeSessionDurationSeconds: activitySample?.claudeSessionDurationSeconds,
            codexTranscriptBytes: activitySample?.codexTranscriptBytes,
            claudeTranscriptBytes: activitySample?.claudeTranscriptBytes,
            codexActiveTranscriptCount: activitySample?.codexActiveTranscriptCount,
            claudeActiveTranscriptCount: activitySample?.claudeActiveTranscriptCount))
    }

    static func recordMenuOpen(at date: Date = Date()) {
        guard self.isEnabled else { return }
        self.activeWriter.append(.menuOpen(timestamp: date))
    }

    static func recordRefreshCompleted(at date: Date = Date()) {
        guard self.isEnabled else { return }
        self.activeWriter.append(.refreshCompleted(timestamp: date))
    }

    /// Records the one place live behavior isn't a plain tick loop: `UsageStore.noteMenuOpened(at:)`
    /// pulling the adaptive timer's next refresh forward because a fresh decision, computed as of
    /// this menu open, would land earlier than what was already scheduled. Call only from the
    /// branch that actually calls `startTimer(preservingResetBoundaryRefresh: true)` — an advance
    /// that was merely *considered* but not taken has no observable scheduling effect, so it isn't
    /// worth a trace line (unlike `recordDecision`, which is unconditional per tick).
    static func recordTimerAdvanced(
        at date: Date = Date(),
        previousScheduledAt: Date?,
        candidateScheduledAt: Date,
        decision: AdaptiveRefreshPolicy.Decision)
    {
        guard self.isEnabled else { return }
        self.activeWriter.append(.timerAdvanced(
            timestamp: date,
            previousScheduledAt: previousScheduledAt,
            candidateScheduledAt: candidateScheduledAt,
            reason: decision.reason.rawValue,
            delaySeconds: TimeInterval(decision.delay.components.seconds)))
    }

    // swiftlint:disable:next function_parameter_count
    static func recordTimerAdvanceEvaluation(
        at date: Date,
        previousScheduledAt: Date?,
        candidateScheduledAt: Date,
        decision: AdaptiveRefreshPolicy.Decision,
        accepted: Bool,
        refreshInFlight: Bool)
    {
        guard self.isEnabled else { return }
        self.activeWriter.append(.timerAdvanceEvaluated(
            timestamp: date,
            previousScheduledAt: previousScheduledAt,
            candidateScheduledAt: candidateScheduledAt,
            reason: decision.reason.rawValue,
            delaySeconds: TimeInterval(decision.delay.components.seconds),
            accepted: accepted,
            refreshInFlight: refreshInFlight))
    }

    private static func replayThermalState(for state: ProcessInfo.ThermalState) -> ReplayThermalState {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }
}
