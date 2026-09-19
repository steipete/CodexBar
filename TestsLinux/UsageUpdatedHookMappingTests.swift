import CodexBarCore
import Foundation
import Testing

struct UsageUpdatedHookMappingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var snapshot: UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: self.now, resetDescription: nil),
            secondary: RateWindow(usedPercent: 40, windowMinutes: 10080, resetsAt: self.now, resetDescription: nil),
            updatedAt: self.now)
    }

    private func config(executable: String = "/usr/bin/true") -> HooksConfig {
        HooksConfig(enabled: true, events: [HookRule(event: .usageUpdated, executable: executable)])
    }

    @Test
    func `shared mapping preserves genuine zero and omits synthetic windows`() throws {
        let zero = HookEvent.usageUpdated(provider: "codex", snapshot: self.snapshot, account: nil, timestamp: self.now)
        #expect(zero.usagePercent == 0)
        #expect(zero.secondaryUsagePercent == 0.4)
        #expect(zero.windowMinutes == 300)
        let placeholder = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: nil,
                isSyntheticPlaceholder: true),
            secondary: nil,
            updatedAt: self.now)
        let event = HookEvent.usageUpdated(provider: "codex", snapshot: placeholder, account: nil, timestamp: self.now)
        let payload = try #require(JSONSerialization.jsonObject(with: event.jsonPayload()) as? [String: Any])
        #expect(event.usagePercent == nil)
        #expect(payload["usagePercent"] == nil)
        #expect(payload["windowMinutes"] == nil)
        #expect(event.environmentVariables()["CODEXBAR_SECONDARY_USAGE_PERCENT"] == nil)
    }

    @Test
    func `watch offers successful first and unchanged polls with private routing state`() throws {
        let detector = HookTransitionDetector()
        let observation = HookProviderObservation(
            provider: "codex",
            accountDisplayName: nil,
            successfulUsage: self.snapshot,
            accountDiscriminator: "private-owner")
        for instant in [self.now, self.now.addingTimeInterval(60)] {
            let dispatches = detector.evaluate(observation: observation, config: self.config(), now: instant)
            #expect(dispatches.count == 1)
            let dispatch = try #require(dispatches.first)
            #expect(dispatch.event == .usageUpdated(
                provider: "codex", snapshot: self.snapshot, account: nil, timestamp: instant))
            #expect(dispatch.accountDiscriminator == "private-owner")
            let payload = try String(decoding: dispatch.event.jsonPayload(), as: UTF8.self)
            #expect(!payload.contains("private-owner"))
            #expect(dispatch.event.environmentVariables()["CODEXBAR_ACCOUNT"] == nil)
        }
    }

    @Test
    func `failed and status only observations cannot emit usage updates`() {
        let detector = HookTransitionDetector()
        let failure = HookProviderObservation(
            provider: "codex",
            refreshFailureStatus: "offline",
            successfulUsage: self.snapshot)
        #expect(detector.evaluate(observation: failure, config: self.config()).map(\.event.event) == [.refreshFailed])
        let statusOnly = HookProviderObservation(provider: "codex", status: .none)
        #expect(detector.evaluate(observation: statusOnly, config: self.config()).isEmpty)
    }

    @Test
    func `private account throttles open at exactly 600 seconds and reset on restart`() async {
        let event = HookEvent.usageUpdated(
            provider: "codex",
            snapshot: self.snapshot,
            account: nil,
            timestamp: self.now)
        let limiter = HookRateLimiter()
        #expect(await limiter.allow(event, accountDiscriminator: "A", now: self.now))
        #expect(await !limiter.allow(event, accountDiscriminator: "A", now: self.now.addingTimeInterval(599)))
        #expect(await limiter.allow(event, accountDiscriminator: "B", now: self.now.addingTimeInterval(599)))
        #expect(await limiter.allow(event, accountDiscriminator: "A", now: self.now.addingTimeInterval(600)))
        #expect(await HookRateLimiter().allow(event, accountDiscriminator: "A", now: self.now))
    }

    @Test
    func `dispatch reports attempts without counting unmatched or throttled candidates`() async {
        let event = HookEvent.usageUpdated(
            provider: "codex",
            snapshot: self.snapshot,
            account: nil,
            timestamp: self.now)
        let limiter = HookRateLimiter()
        let unmatched = await HookRunner.dispatch(
            event: event, config: HooksConfig(enabled: true), rateLimiter: limiter, baseEnvironment: [:])
        #expect(unmatched == .noMatchingRules)
        let first = await HookRunner.dispatch(
            event: event, config: self.config(), rateLimiter: limiter, baseEnvironment: [:])
        #expect(first == .attempted)
        let repeated = await HookRunner.dispatch(
            event: event, config: self.config(), rateLimiter: limiter, baseEnvironment: [:])
        #expect(repeated == .rateLimited)
    }

    @Test
    func `failed command attempts consume the throttle interval`() async {
        let event = HookEvent.usageUpdated(
            provider: "codex",
            snapshot: self.snapshot,
            account: nil,
            timestamp: self.now)
        let limiter = HookRateLimiter()
        let config = self.config(executable: "/nonexistent/codexbar-hook-fixture")
        let first = await HookRunner.dispatch(
            event: event, config: config, rateLimiter: limiter, baseEnvironment: [:])
        let repeated = await HookRunner.dispatch(
            event: event, config: config, rateLimiter: limiter, baseEnvironment: [:])
        #expect(first == .attempted)
        #expect(repeated == .rateLimited)
    }
}
