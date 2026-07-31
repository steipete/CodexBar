import Foundation

/// Identifies one quota lane for hook transition tracking.
///
/// Mirrors the app's `QuotaWarningStateKey` shape: accounts that share a provider,
/// and extra windows within one account, track their crossings independently.
public struct HookQuotaLaneKey: Hashable, Sendable {
    public let provider: String
    public let window: QuotaWarningWindow
    public let accountDiscriminator: String?
    public let windowID: String?

    public init(
        provider: String,
        window: QuotaWarningWindow,
        accountDiscriminator: String? = nil,
        windowID: String? = nil)
    {
        self.provider = provider
        self.window = window
        self.accountDiscriminator = accountDiscriminator
        self.windowID = windowID
    }
}

/// One quota lane observed in a single poll.
public struct HookQuotaLaneObservation: Sendable {
    public let key: HookQuotaLaneKey
    /// Display label for the event payload (e.g. "Session", "Weekly").
    public let label: String
    /// Nil means the lane was not reported this poll.
    public let rateWindow: RateWindow?
    /// Provider notification thresholds as usage fractions, used by `quota_low`
    /// rules that carry no explicit threshold of their own.
    public let fallbackThresholds: [Double]
    public let accountDisplayName: String?

    public init(
        key: HookQuotaLaneKey,
        label: String,
        rateWindow: RateWindow?,
        fallbackThresholds: [Double] = [],
        accountDisplayName: String? = nil)
    {
        self.key = key
        self.label = label
        self.rateWindow = rateWindow
        self.fallbackThresholds = fallbackThresholds
        self.accountDisplayName = accountDisplayName
    }
}

/// Coarse provider availability, mirroring the app's status indicator semantics.
public enum HookProviderStatus: String, Sendable {
    case none
    case minor
    case major
    case critical
    case maintenance
    case unknown

    /// `maintenance` and `unknown` never flip tracked state, so a hiccuped status
    /// probe or a planned window cannot fire an outage hook.
    var outageState: Bool? {
        switch self {
        case .minor, .major, .critical: true
        case .none: false
        case .maintenance, .unknown: nil
        }
    }
}

/// Everything observed for one provider in a single poll.
public struct HookProviderObservation: Sendable {
    public let provider: String
    public let lanes: [HookQuotaLaneObservation]
    public let status: HookProviderStatus
    /// Coarse failure category when the refresh itself failed. Never a raw error
    /// string: provider errors can embed response-body previews.
    public let refreshFailureStatus: String?
    public let accountDisplayName: String?

    public init(
        provider: String,
        lanes: [HookQuotaLaneObservation] = [],
        status: HookProviderStatus = .unknown,
        refreshFailureStatus: String? = nil,
        accountDisplayName: String? = nil)
    {
        self.provider = provider
        self.lanes = lanes
        self.status = status
        self.refreshFailureStatus = refreshFailureStatus
        self.accountDisplayName = accountDisplayName
    }
}

/// Turns successive provider observations into hook events.
///
/// Platform-neutral and side-effect free: it decides *what fired* and never
/// fetches or runs commands. The macOS app keeps its own equivalent wiring in
/// `UsageStore`; this type exists so the CLI can drive the same event semantics
/// headlessly, where `HookRunner` otherwise never runs at all.
///
/// State is in-memory only, matching the app: a restart starts fresh and the
/// first sample of any lane establishes a baseline without firing.
public final class HookTransitionDetector {
    /// Previous usage fraction (0...1) and reset boundary per lane. Drives all
    /// three quota edges: `quota_low` crossing, `quota_reached`, and `quota_reset`.
    private var windowObservation: [HookQuotaLaneKey: LaneSample] = [:]
    /// Previous outage state per provider. Absent until a definite status is seen.
    private var providerStatusHadIssue: [String: Bool] = [:]
    /// Identity of the hook configuration the current baselines were built under.
    private var configRevision: Int?

    /// Usage fraction at or above which a lane counts as depleted.
    private let reachedThreshold: Double
    /// Drop in usage fraction that counts as a reset when no reset boundary moved.
    private let resetDropThreshold: Double

    private struct LaneSample {
        let usage: Double
        let resetsAt: Date?
    }

    public init(reachedThreshold: Double = 1.0, resetDropThreshold: Double = 0.2) {
        self.reachedThreshold = reachedThreshold
        self.resetDropThreshold = resetDropThreshold
    }

    /// Drops every baseline when the hook configuration changed.
    ///
    /// A rule edit, disable, or re-enable must not fire for a transition that
    /// happened while the previous configuration was inactive; the next sample
    /// re-establishes baselines instead.
    public func resetIfConfigurationChanged(revision: Int) {
        guard self.configRevision != revision else { return }
        self.windowObservation.removeAll()
        self.providerStatusHadIssue.removeAll()
        self.configRevision = revision
    }

    /// Evaluates one poll of one provider and returns the events to dispatch.
    ///
    /// Events are edge-triggered against the previous sample, so a condition that
    /// merely persists (a saturated window, an ongoing outage) does not re-fire on
    /// every poll. `HookRunner` relies on this: it deliberately does not
    /// rate-limit quota events because they "dedupe upstream".
    public func evaluate(
        observation: HookProviderObservation,
        config: HooksConfig,
        now: Date = Date()) -> [HookEvent]
    {
        guard config.enabled, config.events.count <= HooksConfig.maximumRuleCount else { return [] }

        var events: [HookEvent] = []

        if let failure = observation.refreshFailureStatus {
            events.append(HookEvent(
                event: .refreshFailed,
                provider: observation.provider,
                account: observation.accountDisplayName,
                status: failure,
                timestamp: now))
            // A failed refresh carries no usable quota or status reading, so it must
            // not disturb baselines: the next successful poll compares against the
            // last real sample rather than firing a phantom transition.
            return events
        }

        events.append(contentsOf: self.statusEvents(observation: observation, now: now))

        let observedKeys = Set(observation.lanes.map(\.key))
        for lane in observation.lanes {
            events.append(contentsOf: self.laneEvents(
                lane: lane,
                provider: observation.provider,
                config: config,
                now: now))
        }
        self.pruneLanes(provider: observation.provider, keeping: observedKeys)

        return events
    }

    // MARK: - Provider status

    private func statusEvents(observation: HookProviderObservation, now: Date) -> [HookEvent] {
        guard let isOutage = observation.status.outageState else { return [] }
        let previous = self.providerStatusHadIssue[observation.provider]
        self.providerStatusHadIssue[observation.provider] = isOutage

        // No transition can be established from the first definite status.
        guard let previous else { return [] }
        guard previous != isOutage else { return [] }

        return [HookEvent(
            event: isOutage ? .providerUnavailable : .providerRecovered,
            provider: observation.provider,
            account: observation.accountDisplayName,
            status: observation.status.rawValue,
            timestamp: now)]
    }

    // MARK: - Quota lanes

    private func laneEvents(
        lane: HookQuotaLaneObservation,
        provider: String,
        config: HooksConfig,
        now: Date) -> [HookEvent]
    {
        // A lane the provider did not report this poll, or a synthesized stand-in
        // for a lane that does not exist, carries no usage to compare. Forget it so
        // a later reappearance starts fresh instead of reporting a stale crossing.
        guard let rateWindow = lane.rateWindow, !rateWindow.isSyntheticPlaceholder else {
            self.windowObservation.removeValue(forKey: lane.key)
            return []
        }

        let current = rateWindow.usedPercent / 100
        let previousSample = self.windowObservation[lane.key]
        self.windowObservation[lane.key] = LaneSample(usage: current, resetsAt: rateWindow.resetsAt)

        // First sample: establish the baseline only. Avoids firing on a fresh start
        // when usage is already high.
        guard let previousSample else { return [] }

        var events: [HookEvent] = []

        let transition = LaneTransition(
            lane: lane,
            provider: provider,
            previous: previousSample,
            current: current,
            rateWindow: rateWindow,
            now: now)

        if let resetEvent = self.resetEvent(transition) {
            // A reset ends the depleted state; the lane starts over from the new
            // reading, so no depletion edge is reported in the same poll.
            events.append(resetEvent)
            return events
        }

        events.append(contentsOf: self.quotaLowEvents(transition, config: config))

        if previousSample.usage < self.reachedThreshold, current >= self.reachedThreshold {
            events.append(transition.event(.quotaReached))
        }

        return events
    }

    /// One lane's before/after readings for a single poll.
    private struct LaneTransition {
        let lane: HookQuotaLaneObservation
        let provider: String
        let previous: LaneSample
        let current: Double
        let rateWindow: RateWindow
        let now: Date

        /// Builds an event for this lane, filling in the shared payload fields.
        func event(_ type: HookEventType) -> HookEvent {
            HookEvent(
                event: type,
                provider: self.provider,
                account: self.lane.accountDisplayName,
                window: self.lane.label,
                usagePercent: self.current,
                resetAt: self.rateWindow.resetsAt,
                timestamp: self.now)
        }
    }

    private func resetEvent(_ transition: LaneTransition) -> HookEvent? {
        let previousReset = transition.previous.resetsAt
        let currentReset = transition.rateWindow.resetsAt
        let boundaryMoved: Bool = if let previousReset, let currentReset {
            currentReset > previousReset
        } else {
            false
        }
        let usageDropped = transition.previous.usage - transition.current >= self.resetDropThreshold
        guard boundaryMoved || usageDropped else { return nil }

        return transition.event(.quotaReset)
    }

    private func quotaLowEvents(_ transition: LaneTransition, config: HooksConfig) -> [HookEvent] {
        let rules = config.events.filter { rule in
            rule.enabled
                && rule.event == .quotaLow
                && (rule.provider == nil || rule.provider == transition.provider)
        }
        guard !rules.isEmpty else { return [] }

        let crossed = QuotaLowHookThreshold.crossedRules(
            rules,
            previousUsage: transition.previous.usage,
            currentUsage: transition.current,
            fallbackThresholds: transition.lane.fallbackThresholds)
        guard !crossed.isEmpty else { return [] }

        return [transition.event(.quotaLow)]
    }

    /// Forgets lanes that disappeared between polls for this provider, so a later
    /// reappearance establishes a fresh baseline.
    private func pruneLanes(provider: String, keeping observed: Set<HookQuotaLaneKey>) {
        self.windowObservation = self.windowObservation.filter { key, _ in
            key.provider != provider || observed.contains(key)
        }
    }
}
