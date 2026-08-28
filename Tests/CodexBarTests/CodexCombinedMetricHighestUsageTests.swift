import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CodexCombinedMetricHighestUsageTests {
    @Test
    func `combined codex metric uses weekly lane when ranking highest usage`() {
        let store = self.makeStore(suiteName: "CodexCombinedMetricHighestUsageTests-weekly-ranking")

        let codexSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 91, windowMinutes: 7 * 24 * 60, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())
        let claudeSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 80, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(codexSnapshot, provider: .codex)
        store._setSnapshotForTesting(claudeSnapshot, provider: .claude)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .codex)
        #expect(highest?.usedPercent == 91)
    }

    @Test
    func `combined codex metric ignores expired weekly lane when ranking highest usage`() {
        let store = self.makeStore(suiteName: "CodexCombinedMetricHighestUsageTests-expired-weekly-ranking")
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 1,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 100,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: now,
                    resetDescription: nil),
                updatedAt: now.addingTimeInterval(-7200)),
            provider: .codex)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 80, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: now),
            provider: .claude)

        let highest = store.providerWithHighestUsage(now: now)
        #expect(highest?.provider == .claude)
        #expect(highest?.usedPercent == 80)
    }

    @Test
    func `combined codex metric excludes an actively binding weekly cap`() {
        let store = self.makeStore(suiteName: "CodexCombinedMetricHighestUsageTests-binding-weekly-cap")
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 1,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 100,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: now.addingTimeInterval(7200),
                    resetDescription: nil),
                updatedAt: now),
            provider: .codex)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 80, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: now),
            provider: .claude)

        let highest = store.providerWithHighestUsage(now: now)
        #expect(highest?.provider == .claude)
        #expect(highest?.usedPercent == 80)
    }

    @Test
    func `combined codex metric stays eligible when only one lane is exhausted`() {
        let store = self.makeStore(suiteName: "CodexCombinedMetricHighestUsageTests-one-exhausted")

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 100, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 30,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: Date()),
            provider: .codex)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 80, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .claude)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .codex)
        #expect(highest?.usedPercent == 100)
    }

    @Test
    func `combined codex metric is excluded when both lanes are exhausted`() {
        let store = self.makeStore(suiteName: "CodexCombinedMetricHighestUsageTests-both-exhausted")

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 100, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 100,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: Date()),
            provider: .codex)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 80, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .claude)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .claude)
        #expect(highest?.usedPercent == 80)
    }

    @Test
    func `combined claude metric stays eligible when only one lane is exhausted`() {
        let store = self.makeStore(
            suiteName: "CodexCombinedMetricHighestUsageTests-claude-one-exhausted",
            claudeCombined: true)

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 50, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 50,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: Date()),
            provider: .codex)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 100, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 30,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: Date()),
            provider: .claude)

        // Claude's session lane is exhausted but the weekly lane still has room, so the combined
        // metric must keep Claude eligible (mirroring Codex) instead of dropping it from ranking.
        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .claude)
        #expect(highest?.usedPercent == 100)
    }

    @Test
    func `combined claude metric is excluded when both lanes are exhausted`() {
        let store = self.makeStore(
            suiteName: "CodexCombinedMetricHighestUsageTests-claude-both-exhausted",
            claudeCombined: true)

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 80, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 80,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: Date()),
            provider: .codex)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 100, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 100,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: Date()),
            provider: .claude)

        // Both Claude lanes are exhausted, so the combined metric must drop Claude from ranking and
        // surface Codex instead.
        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .codex)
        #expect(highest?.usedPercent == 80)
    }

    @Test
    func `combined claude metric excludes an exhausted weekly-only account with a synthetic placeholder`() {
        let store = self.makeStore(
            suiteName: "CodexCombinedMetricHighestUsageTests-claude-placeholder-exhausted",
            claudeCombined: true)

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 80, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 80,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: Date()),
            provider: .codex)
        // Claude web weekly-only account: a synthetic 0% session placeholder plus an exhausted weekly lane.
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 0,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil,
                    isSyntheticPlaceholder: true),
                secondary: RateWindow(
                    usedPercent: 100,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: Date()),
            provider: .claude)

        // The placeholder is not a real lane, so the only real Claude lane (weekly) is fully exhausted —
        // Claude must be excluded from ranking, not kept eligible by the phantom 0% session.
        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .codex)
        #expect(highest?.usedPercent == 80)
    }

    @Test
    func `combined claude metric excludes an exhausted spend-limit-only account`() {
        let store = self.makeStore(
            suiteName: "CodexCombinedMetricHighestUsageTests-claude-spend-limit-exhausted",
            claudeCombined: true)

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 80, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 80,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: Date()),
            provider: .codex)
        // Claude spend-limit-only account: exhausted providerCost, no secondary/tertiary, and an
        // explicitly marked 0% 5h placeholder primary. The metric resolves to the exhausted spend-limit window.
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 0,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil,
                    isSyntheticPlaceholder: true),
                secondary: nil,
                providerCost: ProviderCostSnapshot(
                    used: 100,
                    limit: 100,
                    currencyCode: "USD",
                    period: "Spend limit",
                    updatedAt: Date()),
                updatedAt: Date()),
            provider: .claude)

        // The spend limit is exhausted and there are no real lanes, so Claude must be excluded from
        // ranking (the marked 0% placeholder must not keep it eligible); Codex surfaces instead.
        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .codex)
        #expect(highest?.usedPercent == 80)
    }

    private func makeStore(suiteName: String, claudeCombined: Bool = false) -> UsageStore {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: suiteName),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.setMenuBarMetricPreference(.primaryAndSecondary, for: .codex)
        if claudeCombined {
            settings.setMenuBarMetricPreference(.primaryAndSecondary, for: .claude)
        }

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        return UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
    }
}
