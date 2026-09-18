import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct AntigravityHistoryUpgradeTests {
    @Test
    func `populated version one accounts survive both refresh formats persistence and restart`() async throws {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let disk = store.planUtilizationHistoryStore
        let root = try #require(disk.directoryURL)
        let now = Date(timeIntervalSince1970: 1_789_300_000)
        let account = ProviderTokenAccount(
            id: UUID(), label: "Fixture A", token: "fixture-only", addedAt: 0, lastUsed: nil)
        let key = try #require(UsageStore._planUtilizationTokenAccountKeyForTesting(
            provider: .antigravity, account: account))
        // Literal pre-upgrade schema: no observation series and no newly encoded payload as the input fixture.
        let legacySeries = """
        [{"name":"session","windowMinutes":300,"entries":[
          {"capturedAt":"2026-09-12T00:00:00Z","usedPercent":12,"resetsAt":"2026-09-12T05:00:00Z"}]},
         {"name":"weekly","windowMinutes":10080,"entries":[
          {"capturedAt":"2026-09-12T00:00:00Z","usedPercent":34,"resetsAt":"2026-09-19T00:00:00Z"}]}]
        """
        let document = """
        {"version":1,"preferredAccountKey":"\(key)","unscoped":\(legacySeries),
         "accounts":{"\(key)":\(legacySeries),"fixture-account-b":\(legacySeries)},
         "sessionEquivalentWindowPairIdentities":{"fixture-account-b":"preserve-this-identity"}}
        """
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(document.utf8).write(to: root.appendingPathComponent("antigravity.json"))
        store.planUtilizationHistoryLoaded = false
        store.startPlanUtilizationHistoryLoad(gate: nil, enabled: true)
        await store.planUtilizationHistoryLoadTask?.value
        let before = try #require(store.planUtilizationHistory[UsageProvider.antigravity.instanceID])
        #expect(before.accounts.count == 2)
        #expect(before.histories(for: key).count == 2)
        let pool = UsageSnapshot(
            primary: .init(usedPercent: 82, windowMinutes: nil, resetsAt: now, resetDescription: nil),
            secondary: .init(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: now)
        let session = RateWindow(
            usedPercent: 23, windowMinutes: 300, resetsAt: now.addingTimeInterval(3600), resetDescription: nil)
        let weekly = RateWindow(
            usedPercent: 45, windowMinutes: 10080, resetsAt: now.addingTimeInterval(86400), resetDescription: nil)
        let structured = UsageSnapshot(
            primary: session,
            secondary: weekly,
            extraRateWindows: [
                .init(id: "antigravity-quota-summary-gemini-5h", title: "Gemini 5-hour", window: session),
                .init(id: "antigravity-quota-summary-gemini-weekly", title: "Gemini weekly", window: weekly),
            ],
            updatedAt: now)
        for snapshot in [pool, structured] {
            await store.recordPlanUtilizationHistorySample(
                provider: .antigravity,
                snapshot: snapshot,
                account: account,
                shouldAdoptUnscopedHistory: false,
                now: now)
        }
        let expected = try #require(store.planUtilizationHistory[UsageProvider.antigravity.instanceID])
        let histories = expected.histories(for: key)
        #expect(Set(histories.map(\.name)) == [.session, .weekly, .antigravityGemini, .antigravityClaudeGPT])
        for original in before.histories(for: key) {
            let updated = try #require(histories.first { $0.name == original.name })
            #expect(original.entries.allSatisfy { updated.entries.contains($0) })
            #expect(updated.entries.count == 2)
        }
        #expect(expected.accounts["fixture-account-b"] == before.accounts["fixture-account-b"])
        #expect(expected.unscoped == before.unscoped)
        #expect(expected.sessionEquivalentWindowPairIdentities == before.sessionEquivalentWindowPairIdentities)
        // Wait only for the real async persistence coordinator, with a bounded deadline.
        for _ in 0..<200 {
            if disk.load()[UsageProvider.antigravity.instanceID] == expected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(disk.load()[UsageProvider.antigravity.instanceID] == expected)
        let gate = PlanUtilizationHistoryLoadGate()
        gate.open()
        let restarted = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: store.settings,
            planUtilizationHistoryStore: disk,
            startupBehavior: .testing,
            planUtilizationHistoryLoadGateForTesting: gate)
        await restarted.planUtilizationHistoryLoadTask?.value
        #expect(restarted.planUtilizationHistory[UsageProvider.antigravity.instanceID] == expected)
        for (snapshot, names) in [
            (pool, ["antigravityGemini:0", "antigravityClaudeGPT:0"]),
            // Structured chart presentation intentionally shows the weekly lane; session remains persisted.
            (structured, ["weekly:10080"]),
        ] {
            let chart = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                histories: histories, provider: .antigravity, snapshot: snapshot, referenceDate: now)
            #expect(Set(chart.visibleSeries) == Set(names))
            print("Antigravity upgrade chart: \(chart.visibleSeries); selected=\(chart.selectedSeries ?? "none")")
        }
        print("Antigravity upgrade: 2 accounts and unscoped history preserved; both formats saved and reloaded")
    }
}
