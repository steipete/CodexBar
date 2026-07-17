import CodexBarCore
import Foundation
import Testing

struct QuotaPlanningProviderResolutionTests {
    @Test
    func `only opted in descriptors expose quota planning`() {
        #expect(CodexProviderDescriptor.descriptor.quotaPlanning != nil)
        #expect(ClaudeProviderDescriptor.descriptor.quotaPlanning != nil)
        #expect(AntigravityProviderDescriptor.descriptor.quotaPlanning != nil)
        #expect(ProviderDescriptorRegistry.descriptor(for: .openai).quotaPlanning == nil)
    }

    @Test(arguments: [ProviderObservationFreshness.cached, .unknown])
    func `non-live freshness never resolves pairs`(freshness: ProviderObservationFreshness) throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let capability = try #require(ClaudeProviderDescriptor.descriptor.quotaPlanning)
        let pairs = capability.resolvePairs(for: Self.result(
            usage: Self.primarySecondaryUsage(now: now),
            provider: .claude,
            freshness: freshness))

        #expect(pairs.isEmpty)
    }

    @Test
    func `result freshness defaults to unknown`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let result = ProviderFetchResult(
            usage: Self.primarySecondaryUsage(now: now),
            credits: nil,
            dashboard: nil,
            sourceLabel: "test",
            strategyID: "test.strategy",
            strategyKind: .oauth)

        #expect(result.observationFreshness == .unknown)
    }

    @Test
    func `codex resolves reversed source slots through shared semantic lanes`() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let session = Self.window(used: 20, minutes: 300, reset: now.addingTimeInterval(4 * 3600))
        let weekly = Self.window(used: 30, minutes: 10080, reset: now.addingTimeInterval(6 * 24 * 3600))
        let usage = UsageSnapshot(
            primary: weekly,
            secondary: session,
            updatedAt: now)
        let capability = try #require(CodexProviderDescriptor.descriptor.quotaPlanning)

        let pair = try #require(capability.resolvePairs(for: Self.result(
            usage: usage,
            provider: .codex,
            freshness: .live)).first)

        #expect(pair.id == "session-weekly")
        #expect(pair.short.metricID == "primary")
        #expect(pair.short.window == session)
        #expect(pair.long.metricID == "secondary")
        #expect(pair.long.window == weekly)
    }

    @Test
    func `claude accepts a real session and rejects a synthetic placeholder`() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let capability = try #require(ClaudeProviderDescriptor.descriptor.quotaPlanning)
        let realResult = Self.result(
            usage: Self.primarySecondaryUsage(now: now),
            provider: .claude,
            freshness: .live)
        let placeholderUsage = UsageSnapshot(
            primary: Self.window(
                used: 0,
                minutes: 300,
                reset: now.addingTimeInterval(5 * 3600),
                synthetic: true),
            secondary: Self.window(
                used: 30,
                minutes: 10080,
                reset: now.addingTimeInterval(6 * 24 * 3600)),
            updatedAt: now)

        #expect(capability.resolvePairs(for: realResult).count == 1)
        #expect(capability.resolvePairs(for: Self.result(
            usage: placeholderUsage,
            provider: .claude,
            freshness: .live)).isEmpty)
    }

    @Test
    func `antigravity resolves every complete named group independent of order`() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let windows = [
            Self.namedAntigravityWindow(group: "3p", cadence: "weekly", used: 40, now: now),
            Self.namedAntigravityWindow(group: "gemini", cadence: "5h", used: 10, now: now),
            Self.namedAntigravityWindow(group: "3p", cadence: "5h", used: 20, now: now),
            Self.namedAntigravityWindow(group: "gemini", cadence: "weekly", used: 30, now: now),
        ]
        let usage = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: windows,
            updatedAt: now)
        let capability = try #require(AntigravityProviderDescriptor.descriptor.quotaPlanning)

        let pairs = capability.resolvePairs(for: Self.result(
            usage: usage,
            provider: .antigravity,
            freshness: .live))

        #expect(pairs.map(\.id) == ["quota-summary-3p", "quota-summary-gemini"])
        #expect(pairs.map(\.short.metricID) == [
            "antigravity-quota-summary-3p-5h",
            "antigravity-quota-summary-gemini-5h",
        ])
        #expect(pairs.map(\.long.metricID) == [
            "antigravity-quota-summary-3p-weekly",
            "antigravity-quota-summary-gemini-weekly",
        ])
    }

    @Test
    func `antigravity drops incomplete and ambiguous groups`() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let windows = [
            Self.namedAntigravityWindow(group: "incomplete", cadence: "5h", used: 10, now: now),
            Self.namedAntigravityWindow(group: "duplicate", cadence: "5h", used: 10, now: now),
            Self.namedAntigravityWindow(group: "duplicate", cadence: "session", used: 11, now: now),
            Self.namedAntigravityWindow(group: "duplicate", cadence: "weekly", used: 20, now: now),
            Self.namedAntigravityWindow(group: "valid", cadence: "5h", used: 30, now: now),
            Self.namedAntigravityWindow(group: "valid", cadence: "weekly", used: 40, now: now),
        ]
        let usage = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: windows,
            updatedAt: now)
        let capability = try #require(AntigravityProviderDescriptor.descriptor.quotaPlanning)

        let pairs = capability.resolvePairs(for: Self.result(
            usage: usage,
            provider: .antigravity,
            freshness: .live))

        #expect(pairs.map(\.id) == ["quota-summary-valid"])
    }

    @Test
    func `colliding pair and metric IDs drop every ambiguous pair`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let independent = Self.pair(id: "independent", shortID: "s3", longID: "l3", now: now)
        let capability = ProviderQuotaPlanningCapability { _ in
            [
                Self.pair(id: "one", shortID: "s1", longID: "shared", now: now),
                Self.pair(id: "two", shortID: "s2", longID: "shared", now: now),
                Self.pair(id: "duplicate", shortID: "s4", longID: "l4", now: now),
                Self.pair(id: "duplicate", shortID: "s5", longID: "l5", now: now),
                independent,
            ]
        }

        let pairs = capability.resolvePairs(input: QuotaPlanningResolutionInput(
            usage: Self.primarySecondaryUsage(now: now),
            strategyID: "test.strategy",
            strategyKind: .oauth,
            observationFreshness: .live))

        #expect(pairs == [independent])
    }

    @Test
    func `initial rollout requires supported cadence and strategy identity`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let unsupported = Self.pair(
            id: "daily-monthly",
            shortID: "daily",
            longID: "monthly",
            now: now,
            shortMinutes: 1440,
            longMinutes: 43200)
        let capability = ProviderQuotaPlanningCapability { _ in [unsupported] }

        #expect(capability.resolvePairs(input: QuotaPlanningResolutionInput(
            usage: Self.primarySecondaryUsage(now: now),
            strategyID: "test.strategy",
            strategyKind: .oauth,
            observationFreshness: .live)).isEmpty)
        #expect(ProviderQuotaPlanningCapability { _ in
            [Self.pair(id: "valid", shortID: "short", longID: "long", now: now)]
        }.resolvePairs(input: QuotaPlanningResolutionInput(
            usage: Self.primarySecondaryUsage(now: now),
            strategyID: " ",
            strategyKind: .oauth,
            observationFreshness: .live)).isEmpty)
    }

    private static func result(
        usage: UsageSnapshot,
        provider: UsageProvider,
        freshness: ProviderObservationFreshness) -> ProviderFetchResult
    {
        ProviderFetchResult(
            usage: usage,
            credits: nil,
            dashboard: nil,
            sourceLabel: "test",
            strategyID: "\(provider.rawValue).test",
            strategyKind: .oauth,
            observationFreshness: freshness)
    }

    private static func primarySecondaryUsage(now: Date) -> UsageSnapshot {
        UsageSnapshot(
            primary: self.window(
                used: 20,
                minutes: 300,
                reset: now.addingTimeInterval(4 * 3600)),
            secondary: self.window(
                used: 30,
                minutes: 10080,
                reset: now.addingTimeInterval(6 * 24 * 3600)),
            updatedAt: now)
    }

    private static func namedAntigravityWindow(
        group: String,
        cadence: String,
        used: Double,
        now: Date) -> NamedRateWindow
    {
        let isWeekly = cadence == "weekly"
        return NamedRateWindow(
            id: "antigravity-quota-summary-\(group)-\(cadence)",
            title: "Fixture",
            window: Self.window(
                used: used,
                minutes: isWeekly ? 10080 : 300,
                reset: now.addingTimeInterval(isWeekly ? 6 * 24 * 3600 : 4 * 3600)))
    }

    private static func pair(
        id: String,
        shortID: String,
        longID: String,
        now: Date,
        shortMinutes: Int = 300,
        longMinutes: Int = 10080) -> QuotaPlanningPairSnapshot
    {
        QuotaPlanningPairSnapshot(
            id: id,
            short: QuotaPlanningWindowSnapshot(
                metricID: shortID,
                window: self.window(
                    used: 10,
                    minutes: shortMinutes,
                    reset: now.addingTimeInterval(TimeInterval(shortMinutes * 30)))),
            long: QuotaPlanningWindowSnapshot(
                metricID: longID,
                window: self.window(
                    used: 20,
                    minutes: longMinutes,
                    reset: now.addingTimeInterval(TimeInterval(longMinutes * 30)))))
    }

    private static func window(
        used: Double,
        minutes: Int,
        reset: Date,
        synthetic: Bool = false) -> RateWindow
    {
        RateWindow(
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: reset,
            resetDescription: nil,
            isSyntheticPlaceholder: synthetic)
    }
}
