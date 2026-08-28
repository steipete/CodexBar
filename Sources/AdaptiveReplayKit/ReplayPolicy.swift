import Foundation

// Replay harness for the adaptive refresh policy shipped in the `CodexBar` app target. The app
// and replay adapter both call `AdaptiveRefreshPolicyCore`; these types only normalize replay
// inputs and report replay-friendly output.

/// Coarse thermal-pressure signal matching the two `ProcessInfo.ThermalState` cases the policy
/// distinguishes (`.serious`/`.critical` vs everything else), expressed independently so this
/// library never needs Darwin-only APIs and can build on any platform.
public enum ReplayThermalState: String, Sendable, Codable, CaseIterable {
    case nominal
    case fair
    case serious
    case critical

    public var isConstrained: Bool {
        self == .serious || self == .critical
    }
}

/// The inputs a refresh-timing policy needs to decide how long to wait before the next refresh.
/// Replay-specific policy input. Platform-independent fields map into the shared policy core.
public struct ReplayPolicyInput: Sendable, Equatable {
    public let now: Date
    public let lastMenuOpenAt: Date?
    /// Most recent transcript write reconstructed from the latest activity observation available
    /// at or before `now`. This is nil when that observation could not see either CLI.
    public let lastCodingActivityAt: Date?
    public let lowPowerModeEnabled: Bool
    public let thermalState: ReplayThermalState

    public init(
        now: Date,
        lastMenuOpenAt: Date?,
        lastCodingActivityAt: Date? = nil,
        lowPowerModeEnabled: Bool,
        thermalState: ReplayThermalState)
    {
        self.now = now
        self.lastMenuOpenAt = lastMenuOpenAt
        self.lastCodingActivityAt = lastCodingActivityAt
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.thermalState = thermalState
    }

    /// Whether this input represents a power/thermal-constrained moment, independent of which
    /// policy is deciding. Used by the replay engine to score constrained-tier compliance without
    /// depending on any single policy's own notion of "constrained".
    public var isConstrained: Bool {
        self.lowPowerModeEnabled || self.thermalState.isConstrained
    }

    public var codingActivityAgeSeconds: TimeInterval? {
        self.lastCodingActivityAt.map { max(0, self.now.timeIntervalSince($0)) }
    }
}

/// A policy's decision: how long to wait, and a short human-readable reason code for reporting.
/// `delaySeconds == nil` means "never schedule another refresh" — the degenerate floor used by
/// `ManualPolicy`.
public struct ReplayPolicyDecision: Sendable, Equatable {
    public let delaySeconds: TimeInterval?
    public let reason: String

    public init(delaySeconds: TimeInterval?, reason: String) {
        self.delaySeconds = delaySeconds
        self.reason = reason
    }
}

/// A pure, deterministic function from `ReplayPolicyInput` to `ReplayPolicyDecision`.
public protocol ReplayPolicy: Sendable {
    var name: String { get }

    /// Whether opening the menu can pull this policy's next refresh forward, mirroring
    /// `UsageStore.noteMenuOpened(at:)`'s guard on `settings.refreshFrequency == .adaptive`: in the
    /// real app, only adaptive mode ever advances the timer from an interaction — fixed-cadence and
    /// manual modes just record `lastMenuOpenAt` and let the existing schedule run. Defaults to
    /// `false` so baseline policies (`FixedIntervalPolicy`, `ManualPolicy`) need no override; only
    /// policies that actually model the adaptive table set this to `true`.
    var advancesOnInteraction: Bool { get }

    func decide(_ input: ReplayPolicyInput) -> ReplayPolicyDecision
}

extension ReplayPolicy {
    public var advancesOnInteraction: Bool {
        false
    }
}
