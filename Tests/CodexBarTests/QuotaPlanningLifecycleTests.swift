import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct QuotaPlanningLifecycleTests {
    @Test
    func `live observations publish an estimate keyed by long metric`() throws {
        let fixture = Self.fixture()
        var lifecycle = QuotaPlanningLifecycle()

        Self.recordBaseline(in: &lifecycle, fixture: fixture)
        Self.recordQualifiedObservation(in: &lifecycle, fixture: fixture)

        let estimate = try #require(lifecycle.estimatesByProvider()[.claude]?["weekly"])
        #expect(estimate.pairID == "session-weekly")
        #expect(Self.close(estimate.longPercentPerFullShortAllowance, 5))
    }

    @Test(arguments: [ProviderObservationFreshness.cached, .unknown])
    func `same scope non-live successes retain publication without extending ttl`(
        freshness: ProviderObservationFreshness) throws
    {
        let fixture = Self.fixture()
        var lifecycle = QuotaPlanningLifecycle()
        Self.recordBaseline(in: &lifecycle, fixture: fixture)
        Self.recordQualifiedObservation(in: &lifecycle, fixture: fixture)
        let originalExpiry = try #require(
            lifecycle.publications[.claude]?["weekly"]?.monotonicExpiresAt)

        lifecycle.recordSuccessfulFetch(
            provider: .claude,
            accountDiscriminator: "account-a",
            result: Self.result(freshness: freshness),
            resolvedPairs: [],
            receipt: QuotaPlanningReceipt(
                wallNow: fixture.now.addingTimeInterval(20 * 60),
                monotonicNow: fixture.monotonic.advanced(by: .seconds(20 * 60))))

        #expect(lifecycle.publications[.claude]?["weekly"]?.monotonicExpiresAt == originalExpiry)
        lifecycle.expire(
            wallNow: fixture.now.addingTimeInterval(61 * 60),
            monotonicNow: fixture.monotonic.advanced(by: .seconds(61 * 60)))
        #expect(lifecycle.publications[.claude] == nil)
        #expect(lifecycle.calibrations.count == 1)
    }

    @Test
    func `live ineligible result hides publication but preserves calibration`() {
        let fixture = Self.fixture()
        var lifecycle = QuotaPlanningLifecycle()
        Self.recordBaseline(in: &lifecycle, fixture: fixture)
        Self.recordQualifiedObservation(in: &lifecycle, fixture: fixture)

        lifecycle.recordSuccessfulFetch(
            provider: .claude,
            accountDiscriminator: "account-a",
            result: Self.result(freshness: .live),
            resolvedPairs: [],
            receipt: QuotaPlanningReceipt(
                wallNow: fixture.now.addingTimeInterval(120),
                monotonicNow: fixture.monotonic.advanced(by: .seconds(120))))

        #expect(lifecycle.publications[.claude] == nil)
        #expect(lifecycle.calibrations.count == 1)
    }

    @Test
    func `strategy change hides old publication and isolates calibration`() {
        let fixture = Self.fixture()
        var lifecycle = QuotaPlanningLifecycle()
        Self.recordBaseline(in: &lifecycle, fixture: fixture)
        Self.recordQualifiedObservation(in: &lifecycle, fixture: fixture)

        lifecycle.recordSuccessfulFetch(
            provider: .claude,
            accountDiscriminator: "account-a",
            result: Self.result(freshness: .live, strategyID: "claude.cli", kind: .cli),
            resolvedPairs: [Self.pair(
                fixture: fixture,
                shortUsed: 0,
                longUsed: 13)],
            receipt: QuotaPlanningReceipt(
                wallNow: fixture.now.addingTimeInterval(120),
                monotonicNow: fixture.monotonic.advanced(by: .seconds(120))))

        #expect(lifecycle.publications[.claude] == nil)
        #expect(lifecycle.calibrations.count == 2)
        #expect(lifecycle.activeScopes[.claude]?.strategyID == "claude.cli")
    }

    @Test
    func `non-live strategy change hides without learning`() {
        let fixture = Self.fixture()
        var lifecycle = QuotaPlanningLifecycle()
        Self.recordBaseline(in: &lifecycle, fixture: fixture)
        Self.recordQualifiedObservation(in: &lifecycle, fixture: fixture)

        lifecycle.recordSuccessfulFetch(
            provider: .claude,
            accountDiscriminator: "account-a",
            result: Self.result(freshness: .cached, strategyID: "claude.cli", kind: .cli),
            resolvedPairs: [],
            receipt: QuotaPlanningReceipt(
                wallNow: fixture.now.addingTimeInterval(120),
                monotonicNow: fixture.monotonic.advanced(by: .seconds(120))))

        #expect(lifecycle.publications[.claude] == nil)
        #expect(lifecycle.calibrations.count == 1)
    }

    @Test
    func `active account change hides publication before another success`() {
        let fixture = Self.fixture()
        var lifecycle = QuotaPlanningLifecycle()
        Self.recordBaseline(in: &lifecycle, fixture: fixture)
        Self.recordQualifiedObservation(in: &lifecycle, fixture: fixture)

        let changed = lifecycle.activateAccount(
            provider: .claude,
            accountDiscriminator: "account-b")

        #expect(changed)
        #expect(lifecycle.publications[.claude] == nil)
        #expect(lifecycle.calibrations.count == 1)
    }

    @Test
    func `short reset expiry hides publication and retains calibration`() {
        let fixture = Self.fixture(shortResetOffset: 30 * 60)
        var lifecycle = QuotaPlanningLifecycle()
        Self.recordBaseline(in: &lifecycle, fixture: fixture)
        Self.recordQualifiedObservation(in: &lifecycle, fixture: fixture)

        lifecycle.expire(
            wallNow: fixture.shortReset.addingTimeInterval(1),
            monotonicNow: fixture.monotonic.advanced(by: .seconds(31 * 60)))

        #expect(lifecycle.publications[.claude] == nil)
        #expect(lifecycle.calibrations.count == 1)
    }

    @Test
    func `long reset expiry discards publication and calibration`() {
        let fixture = Self.fixture(shortResetOffset: 30 * 60, longResetOffset: 40 * 60)
        var lifecycle = QuotaPlanningLifecycle()
        Self.recordBaseline(in: &lifecycle, fixture: fixture)
        Self.recordQualifiedObservation(in: &lifecycle, fixture: fixture)

        lifecycle.expire(
            wallNow: fixture.longReset.addingTimeInterval(1),
            monotonicNow: fixture.monotonic.advanced(by: .seconds(41 * 60)))

        #expect(lifecycle.publications[.claude] == nil)
        #expect(lifecycle.calibrations.isEmpty)
    }

    @Test
    func `missing stable account never learns or publishes`() {
        let fixture = Self.fixture()
        var lifecycle = QuotaPlanningLifecycle()

        lifecycle.recordSuccessfulFetch(
            provider: .claude,
            accountDiscriminator: nil,
            result: Self.result(freshness: .live),
            resolvedPairs: [Self.pair(
                fixture: fixture,
                shortUsed: 0,
                longUsed: 10)],
            receipt: QuotaPlanningReceipt(
                wallNow: fixture.now,
                monotonicNow: fixture.monotonic))

        #expect(lifecycle.calibrations.isEmpty)
        #expect(lifecycle.publications.isEmpty)
    }

    @Test
    func `independent pairs publish by their own long metric ids`() throws {
        let fixture = Self.fixture()
        var lifecycle = QuotaPlanningLifecycle()

        lifecycle.recordSuccessfulFetch(
            provider: .antigravity,
            accountDiscriminator: "account-a",
            result: Self.result(freshness: .live, strategyID: "antigravity.local", kind: .localProbe),
            resolvedPairs: [
                Self.pair(
                    fixture: fixture,
                    pairID: "gemini",
                    longMetricID: "gemini-weekly",
                    shortUsed: 0,
                    longUsed: 10),
                Self.pair(
                    fixture: fixture,
                    pairID: "third-party",
                    longMetricID: "third-party-weekly",
                    shortUsed: 0,
                    longUsed: 20),
            ],
            receipt: QuotaPlanningReceipt(
                wallNow: fixture.now,
                monotonicNow: fixture.monotonic))
        lifecycle.recordSuccessfulFetch(
            provider: .antigravity,
            accountDiscriminator: "account-a",
            result: Self.result(freshness: .live, strategyID: "antigravity.local", kind: .localProbe),
            resolvedPairs: [
                Self.pair(
                    fixture: fixture,
                    pairID: "gemini",
                    longMetricID: "gemini-weekly",
                    shortUsed: 60,
                    longUsed: 13),
                Self.pair(
                    fixture: fixture,
                    pairID: "third-party",
                    longMetricID: "third-party-weekly",
                    shortUsed: 50,
                    longUsed: 23),
            ],
            receipt: QuotaPlanningReceipt(
                wallNow: fixture.now.addingTimeInterval(60),
                monotonicNow: fixture.monotonic.advanced(by: .seconds(60))))

        let estimates = try #require(lifecycle.estimatesByProvider()[.antigravity])
        #expect(Set(estimates.keys) == ["gemini-weekly", "third-party-weekly"])
        #expect(try Self.close(
            #require(estimates["gemini-weekly"])
                .longPercentPerFullShortAllowance,
            5))
        #expect(try Self.close(
            #require(estimates["third-party-weekly"])
                .longPercentPerFullShortAllowance,
            6))
    }

    @Test
    func `identity discriminator is normalized and does not expose email`() throws {
        let first = try #require(UsageStore.quotaPlanningIdentityDiscriminator(
            provider: .antigravity,
            usage: Self.usage(email: " Person@Example.com ")))
        let second = try #require(UsageStore.quotaPlanningIdentityDiscriminator(
            provider: .antigravity,
            usage: Self.usage(email: "person@example.com")))

        #expect(first == second)
        #expect(!first.contains("person@example.com"))
    }

    @Test
    func `earliest expiry uses monotonic ttl when resets are later`() throws {
        let fixture = Self.fixture()
        var lifecycle = QuotaPlanningLifecycle()
        Self.recordBaseline(in: &lifecycle, fixture: fixture)
        Self.recordQualifiedObservation(in: &lifecycle, fixture: fixture)

        let delay = try #require(lifecycle.nextExpiryDelay(
            wallNow: fixture.now.addingTimeInterval(60),
            monotonicNow: fixture.monotonic.advanced(by: .seconds(60))))

        #expect(delay == .seconds(60 * 60))
    }

    private struct Fixture {
        let now: Date
        let monotonic: ContinuousClock.Instant
        let shortReset: Date
        let longReset: Date
    }

    private static func fixture(
        shortResetOffset: TimeInterval = 4 * 60 * 60,
        longResetOffset: TimeInterval = 6 * 24 * 60 * 60) -> Fixture
    {
        let now = Date(timeIntervalSince1970: 1_000_000)
        return Fixture(
            now: now,
            monotonic: ContinuousClock().now,
            shortReset: now.addingTimeInterval(shortResetOffset),
            longReset: now.addingTimeInterval(longResetOffset))
    }

    private static func recordBaseline(
        in lifecycle: inout QuotaPlanningLifecycle,
        fixture: Fixture)
    {
        lifecycle.recordSuccessfulFetch(
            provider: .claude,
            accountDiscriminator: "account-a",
            result: self.result(freshness: .live),
            resolvedPairs: [self.pair(
                fixture: fixture,
                shortUsed: 0,
                longUsed: 10)],
            receipt: QuotaPlanningReceipt(
                wallNow: fixture.now,
                monotonicNow: fixture.monotonic))
    }

    private static func recordQualifiedObservation(
        in lifecycle: inout QuotaPlanningLifecycle,
        fixture: Fixture)
    {
        let capturedAt = fixture.now.addingTimeInterval(60)
        lifecycle.recordSuccessfulFetch(
            provider: .claude,
            accountDiscriminator: "account-a",
            result: Self.result(freshness: .live),
            resolvedPairs: [Self.pair(
                fixture: fixture,
                shortUsed: 60,
                longUsed: 13)],
            receipt: QuotaPlanningReceipt(
                wallNow: capturedAt,
                monotonicNow: fixture.monotonic.advanced(by: .seconds(60))))
    }

    private static func pair(
        fixture: Fixture,
        pairID: String = "session-weekly",
        longMetricID: String = "weekly",
        shortUsed: Double,
        longUsed: Double) -> QuotaPlanningPairSnapshot
    {
        QuotaPlanningPairSnapshot(
            id: pairID,
            short: QuotaPlanningWindowSnapshot(
                metricID: "\(pairID)-session",
                window: RateWindow(
                    usedPercent: shortUsed,
                    windowMinutes: 300,
                    resetsAt: fixture.shortReset,
                    resetDescription: nil)),
            long: QuotaPlanningWindowSnapshot(
                metricID: longMetricID,
                window: RateWindow(
                    usedPercent: longUsed,
                    windowMinutes: 10080,
                    resetsAt: fixture.longReset,
                    resetDescription: nil)))
    }

    private static func usage(email: String) -> UsageSnapshot {
        UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: .init(),
            identity: ProviderIdentitySnapshot(
                providerID: .antigravity,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: nil))
    }

    private static func result(
        freshness: ProviderObservationFreshness,
        strategyID: String = "claude.oauth",
        kind: ProviderFetchKind = .oauth) -> ProviderFetchResult
    {
        ProviderFetchResult(
            usage: UsageSnapshot(primary: nil, secondary: nil, updatedAt: .init()),
            credits: nil,
            dashboard: nil,
            sourceLabel: "test",
            strategyID: strategyID,
            strategyKind: kind,
            observationFreshness: freshness)
    }

    private static func close(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.0001) -> Bool {
        abs(lhs - rhs) <= tolerance
    }
}
