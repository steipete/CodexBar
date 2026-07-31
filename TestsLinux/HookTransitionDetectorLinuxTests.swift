import CodexBarCore
import Foundation
import Testing

struct HookTransitionDetectorLinuxTests {
    private static let provider = "codex"

    private static func laneKey(
        window: QuotaWarningWindow = .session,
        account: String? = nil,
        windowID: String? = nil) -> HookQuotaLaneKey
    {
        HookQuotaLaneKey(
            provider: self.provider,
            window: window,
            accountDiscriminator: account,
            windowID: windowID)
    }

    private static func rateWindow(
        usedPercent: Double,
        resetsAt: Date? = nil,
        isSyntheticPlaceholder: Bool = false) -> RateWindow
    {
        RateWindow(
            usedPercent: usedPercent,
            windowMinutes: 300,
            resetsAt: resetsAt,
            resetDescription: nil,
            isSyntheticPlaceholder: isSyntheticPlaceholder)
    }

    private static func lane(
        usedPercent: Double?,
        key: HookQuotaLaneKey = laneKey(),
        resetsAt: Date? = nil,
        thresholds: [Double] = [0.8],
        isSyntheticPlaceholder: Bool = false) -> HookQuotaLaneObservation
    {
        HookQuotaLaneObservation(
            key: key,
            label: key.window == .session ? "Session" : "Weekly",
            rateWindow: usedPercent.map {
                self.rateWindow(usedPercent: $0, resetsAt: resetsAt, isSyntheticPlaceholder: isSyntheticPlaceholder)
            },
            fallbackThresholds: thresholds)
    }

    private static func observation(
        lanes: [HookQuotaLaneObservation],
        status: HookProviderStatus = .unknown,
        refreshFailureStatus: String? = nil) -> HookProviderObservation
    {
        HookProviderObservation(
            provider: self.provider,
            lanes: lanes,
            status: status,
            refreshFailureStatus: refreshFailureStatus)
    }

    private static func config(
        enabled: Bool = true,
        rules: [HookRule]? = nil) -> HooksConfig
    {
        HooksConfig(
            enabled: enabled,
            events: rules ?? [
                HookRule(event: .quotaLow, executable: "/bin/true"),
                HookRule(event: .quotaReached, executable: "/bin/true"),
                HookRule(event: .quotaReset, executable: "/bin/true"),
                HookRule(event: .providerUnavailable, executable: "/bin/true"),
                HookRule(event: .providerRecovered, executable: "/bin/true"),
                HookRule(event: .refreshFailed, executable: "/bin/true"),
            ])
    }

    // MARK: - Baseline behavior

    @Test
    func `first sample establishes baseline without firing`() {
        let detector = HookTransitionDetector()
        let dispatches = detector.evaluate(
            observation: Self.observation(lanes: [Self.lane(usedPercent: 95)]),
            config: Self.config())
        #expect(dispatches.isEmpty)
    }

    @Test
    func `quota low fires once on upward crossing`() {
        let detector = HookTransitionDetector()
        let cfg = Self.config()
        _ = detector.evaluate(observation: Self.observation(lanes: [Self.lane(usedPercent: 50)]), config: cfg)

        let crossing = detector.evaluate(
            observation: Self.observation(lanes: [Self.lane(usedPercent: 85)]),
            config: cfg)
        #expect(crossing.map(\.event.event) == [.quotaLow])

        // Still above the threshold, but no new crossing: must not re-fire.
        let persisting = detector.evaluate(
            observation: Self.observation(lanes: [Self.lane(usedPercent: 90)]),
            config: cfg)
        #expect(persisting.isEmpty)
    }

    @Test
    func `quota low dispatches only the rule whose threshold crossed`() {
        // Regression: two rules at 50% and 80%. Baseline at 60% already sits above
        // the 50% rule's threshold. When usage later crosses 80%, only the 80% rule
        // crossed this poll — the 50% rule must not be re-dispatched.
        let detector = HookTransitionDetector()
        let cfg = Self.config(rules: [
            HookRule(id: "low", event: .quotaLow, threshold: 0.5, executable: "/bin/true"),
            HookRule(id: "high", event: .quotaLow, threshold: 0.8, executable: "/bin/true"),
        ])
        _ = detector.evaluate(observation: Self.observation(lanes: [Self.lane(usedPercent: 60)]), config: cfg)

        let dispatches = detector.evaluate(
            observation: Self.observation(lanes: [Self.lane(usedPercent: 85)]),
            config: cfg)

        #expect(dispatches.count == 1)
        #expect(dispatches.first?.rules?.map(\.id) == ["high"])
    }

    @Test
    func `quota reached fires on upward edge only and not while saturated`() {
        let detector = HookTransitionDetector()
        let cfg = Self.config()
        _ = detector.evaluate(observation: Self.observation(lanes: [Self.lane(usedPercent: 90)]), config: cfg)

        let reached = detector.evaluate(
            observation: Self.observation(lanes: [Self.lane(usedPercent: 100)]),
            config: cfg)
        #expect(reached.contains { $0.event.event == .quotaReached })

        let stillFull = detector.evaluate(
            observation: Self.observation(lanes: [Self.lane(usedPercent: 100)]),
            config: cfg)
        #expect(!stillFull.contains { $0.event.event == .quotaReached })
    }

    @Test
    func `quota reached never fires for the weekly lane`() {
        // Regression: quota_reached is documented as session-only. A weekly lane
        // reaching 100% must rely on quota_reset, not fire quota_reached too.
        let detector = HookTransitionDetector()
        let cfg = Self.config()
        let weekly = Self.laneKey(window: .weekly)
        _ = detector.evaluate(
            observation: Self.observation(lanes: [Self.lane(usedPercent: 90, key: weekly)]),
            config: cfg)

        let dispatches = detector.evaluate(
            observation: Self.observation(lanes: [Self.lane(usedPercent: 100, key: weekly)]),
            config: cfg)
        #expect(!dispatches.contains { $0.event.event == .quotaReached })
    }

    // MARK: - Reset detection

    @Test
    func `quota reset fires when reset boundary advances`() {
        let detector = HookTransitionDetector()
        let cfg = Self.config()
        let first = Date(timeIntervalSince1970: 1_000_000)
        let second = first.addingTimeInterval(18000)

        _ = detector.evaluate(
            observation: Self.observation(lanes: [Self.lane(usedPercent: 100, resetsAt: first)]),
            config: cfg)
        let dispatches = detector.evaluate(
            observation: Self.observation(lanes: [Self.lane(usedPercent: 0, resetsAt: second)]),
            config: cfg)

        #expect(dispatches.map(\.event.event) == [.quotaReset])
    }

    @Test
    func `quota reset fires on usage drop without reset boundary`() {
        let detector = HookTransitionDetector()
        let cfg = Self.config()
        _ = detector.evaluate(observation: Self.observation(lanes: [Self.lane(usedPercent: 95)]), config: cfg)

        let dispatches = detector.evaluate(
            observation: Self.observation(lanes: [Self.lane(usedPercent: 10)]),
            config: cfg)
        #expect(dispatches.map(\.event.event) == [.quotaReset])
    }

    @Test
    func `reset suppresses depletion edge in same poll`() {
        let detector = HookTransitionDetector()
        let cfg = Self.config()
        _ = detector.evaluate(observation: Self.observation(lanes: [Self.lane(usedPercent: 95)]), config: cfg)

        let dispatches = detector.evaluate(
            observation: Self.observation(lanes: [Self.lane(usedPercent: 5)]),
            config: cfg)
        #expect(!dispatches.contains { $0.event.event == .quotaReached })
    }

    // MARK: - Provider status

    @Test
    func `provider status fires outage and recovery edges`() {
        let detector = HookTransitionDetector()
        let cfg = Self.config()
        _ = detector.evaluate(observation: Self.observation(lanes: [], status: .none), config: cfg)

        let outage = detector.evaluate(observation: Self.observation(lanes: [], status: .major), config: cfg)
        #expect(outage.map(\.event.event) == [.providerUnavailable])

        let persisting = detector.evaluate(
            observation: Self.observation(lanes: [], status: .critical),
            config: cfg)
        #expect(persisting.isEmpty)

        let recovered = detector.evaluate(observation: Self.observation(lanes: [], status: .none), config: cfg)
        #expect(recovered.map(\.event.event) == [.providerRecovered])
    }

    @Test
    func `unknown and maintenance never flip status state`() {
        let detector = HookTransitionDetector()
        let cfg = Self.config()
        _ = detector.evaluate(observation: Self.observation(lanes: [], status: .none), config: cfg)

        let unknown = detector.evaluate(observation: Self.observation(lanes: [], status: .unknown), config: cfg)
        #expect(unknown.isEmpty)
        let maintenance = detector.evaluate(
            observation: Self.observation(lanes: [], status: .maintenance),
            config: cfg)
        #expect(maintenance.isEmpty)

        // The tracked state is still "no outage", so a real outage still fires.
        let outage = detector.evaluate(observation: Self.observation(lanes: [], status: .major), config: cfg)
        #expect(outage.map(\.event.event) == [.providerUnavailable])
    }

    @Test
    func `first definite status does not fire`() {
        let detector = HookTransitionDetector()
        let dispatches = detector.evaluate(
            observation: Self.observation(lanes: [], status: .critical),
            config: Self.config())
        #expect(dispatches.isEmpty)
    }

    // MARK: - Refresh failures

    @Test
    func `refresh failure emits coarse status only`() {
        let detector = HookTransitionDetector()
        let dispatches = detector.evaluate(
            observation: Self.observation(lanes: [], refreshFailureStatus: "timeout"),
            config: Self.config())
        #expect(dispatches.map(\.event.event) == [.refreshFailed])
        #expect(dispatches.first?.event.status == "timeout")
    }

    @Test
    func `refresh failure does not disturb quota baselines`() {
        let detector = HookTransitionDetector()
        let cfg = Self.config()
        _ = detector.evaluate(observation: Self.observation(lanes: [Self.lane(usedPercent: 50)]), config: cfg)
        _ = detector.evaluate(
            observation: Self.observation(lanes: [], refreshFailureStatus: "offline"),
            config: cfg)

        // Compares against the last real sample (50), so this is a genuine crossing.
        let dispatches = detector.evaluate(
            observation: Self.observation(lanes: [Self.lane(usedPercent: 85)]),
            config: cfg)
        #expect(dispatches.contains { $0.event.event == .quotaLow })
    }

    // MARK: - Configuration and lane lifecycle

    @Test
    func `disabled hooks produce no events`() {
        let detector = HookTransitionDetector()
        let cfg = Self.config(enabled: false)
        _ = detector.evaluate(observation: Self.observation(lanes: [Self.lane(usedPercent: 50)]), config: cfg)
        let dispatches = detector.evaluate(
            observation: Self.observation(lanes: [Self.lane(usedPercent: 95)]),
            config: cfg)
        #expect(dispatches.isEmpty)
    }

    @Test
    func `configuration change clears baselines`() {
        let detector = HookTransitionDetector()
        let cfg = Self.config()
        detector.resetIfConfigurationChanged(revision: 1)
        _ = detector.evaluate(observation: Self.observation(lanes: [Self.lane(usedPercent: 50)]), config: cfg)

        // A rule edit must not fire for a crossing that spans the change.
        detector.resetIfConfigurationChanged(revision: 2)
        let dispatches = detector.evaluate(
            observation: Self.observation(lanes: [Self.lane(usedPercent: 95)]),
            config: cfg)
        #expect(dispatches.isEmpty)
    }

    @Test
    func `synthetic placeholder lane never fires`() {
        let detector = HookTransitionDetector()
        let cfg = Self.config()
        _ = detector.evaluate(observation: Self.observation(lanes: [Self.lane(usedPercent: 50)]), config: cfg)

        let dispatches = detector.evaluate(
            observation: Self.observation(lanes: [
                Self.lane(usedPercent: 100, isSyntheticPlaceholder: true),
            ]),
            config: cfg)
        #expect(dispatches.isEmpty)
    }

    @Test
    func `disappearing lane resets baseline`() {
        let detector = HookTransitionDetector()
        let cfg = Self.config()
        _ = detector.evaluate(observation: Self.observation(lanes: [Self.lane(usedPercent: 50)]), config: cfg)
        // Lane not reported this poll.
        _ = detector.evaluate(observation: Self.observation(lanes: []), config: cfg)

        // Reappears high: treated as a fresh baseline, so nothing fires.
        let dispatches = detector.evaluate(
            observation: Self.observation(lanes: [Self.lane(usedPercent: 95)]),
            config: cfg)
        #expect(dispatches.isEmpty)
    }

    @Test
    func `accounts on same provider track independently`() {
        let detector = HookTransitionDetector()
        let cfg = Self.config()
        let first = Self.laneKey(account: "a@example.com")
        let second = Self.laneKey(account: "b@example.com")

        _ = detector.evaluate(
            observation: Self.observation(lanes: [
                Self.lane(usedPercent: 50, key: first),
                Self.lane(usedPercent: 50, key: second),
            ]),
            config: cfg)

        let dispatches = detector.evaluate(
            observation: Self.observation(lanes: [
                Self.lane(usedPercent: 85, key: first),
                Self.lane(usedPercent: 55, key: second),
            ]),
            config: cfg)

        // Only the crossing account fires.
        #expect(dispatches.count == 1)
        #expect(dispatches.first?.event.event == .quotaLow)
    }

    @Test
    func `quota low respects explicit rule threshold over fallback`() {
        let detector = HookTransitionDetector()
        let cfg = Self.config(rules: [
            HookRule(event: .quotaLow, threshold: 0.9, executable: "/bin/true"),
        ])
        _ = detector.evaluate(
            observation: Self.observation(lanes: [Self.lane(usedPercent: 50, thresholds: [0.8])]),
            config: cfg)

        // Crosses the fallback 0.8 but not the rule's own 0.9.
        let below = detector.evaluate(
            observation: Self.observation(lanes: [Self.lane(usedPercent: 85, thresholds: [0.8])]),
            config: cfg)
        #expect(below.isEmpty)

        let above = detector.evaluate(
            observation: Self.observation(lanes: [Self.lane(usedPercent: 95, thresholds: [0.8])]),
            config: cfg)
        #expect(above.map(\.event.event) == [.quotaLow])
    }

    @Test
    func `quota low ignores rules scoped to another provider`() {
        let detector = HookTransitionDetector()
        let cfg = Self.config(rules: [
            HookRule(event: .quotaLow, provider: "claude", executable: "/bin/true"),
        ])
        _ = detector.evaluate(observation: Self.observation(lanes: [Self.lane(usedPercent: 50)]), config: cfg)
        let dispatches = detector.evaluate(
            observation: Self.observation(lanes: [Self.lane(usedPercent: 95)]),
            config: cfg)
        #expect(dispatches.isEmpty)
    }
}
