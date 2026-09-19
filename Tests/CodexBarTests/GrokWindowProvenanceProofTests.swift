import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct GrokWindowProvenanceProofTests: GrokLocalSessionScannerTestSupport {
    @Test(arguments: [false, true])
    func `completed turn logs retain their cost source through the live window`(estimatedRecently: Bool) throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let now = Date()
        let recent = try #require(Calendar.current.date(byAdding: .day, value: -2, to: now))
        let older = try #require(Calendar.current.date(byAdding: .day, value: -120, to: now))
        let recordedUsage = self.usage(
            input: 1000,
            output: 0,
            modelCalls: 1,
            costUsdTicks: 10_000_000_000,
            modelUsage: ["grok-4.6-build": self.modelUsage(input: 1000, output: 0, modelCalls: 1)])
        let estimatedUsage = self.singleModelUsage(input: 1000, output: 0)
        try self.writeUpdates(
            [
                self.turn(timestamp: older, usage: estimatedRecently ? recordedUsage : estimatedUsage),
                self.turn(timestamp: recent, usage: estimatedRecently ? estimatedUsage : recordedUsage),
            ],
            to: fixture.session.appendingPathComponent("updates.jsonl"),
            modificationDate: now)
        let summary = try GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": fixture.root.path],
            lookbackDays: 365,
            now: now,
            modelsDevCatalog: Self.catalog())
        let published = try #require(summary.toCostUsageTokenSnapshot(historyDays: 365))
        let store = Self.makeStore()
        store.publishTokenSnapshot(published, for: .grok)
        // An available billing snapshot without local costs must still consume the newer local publication.
        let remote = UsageSnapshot(primary: nil, secondary: nil, updatedAt: now.addingTimeInterval(-60))
        let selected = try #require(store.tokenSnapshotForLiveProviderConsumer(
            fromProviderSnapshot: remote, provider: .grok, historyDays: 30))
        let expectedSource: CostProvenance = estimatedRecently ? .listPriceEstimate : .vendorMetered
        let expectedCost = estimatedRecently ? 0.002 : 1

        #expect(published.costProvenance == .mixed)
        #expect(selected.historyDays == 30)
        #expect(selected.last30DaysTokens == 1000)
        #expect(abs((selected.last30DaysCostUSD ?? 0) - expectedCost) < 1e-12)
        #expect(selected.costProvenance == expectedSource)
        try Self.verifySurfaces(selected, days: 30)
        // The dashboard retains the full scan and applies its own range/day selection after capture.
        // Exercise that path too, rather than giving it an already narrowed snapshot.
        for (days, selectedDay) in [(30, Date?.none), (365, Optional(recent))] {
            let dashboard = SpendDashboardModel.build(
                inputs: [.init(provider: .grok, displayName: "Grok", snapshot: published)],
                requestedDays: days,
                now: now,
                selectedDay: selectedDay)
            let group = try #require(dashboard.groups.first)
            #expect(group.provenance == expectedSource)
            print("fixture_dashboard_filter=\(selectedDay == nil ? "30-day-window" : "selected-day")")
            print("fixture_dashboard_source=\(group.provenance.rawValue)")
        }
        print("fixture_full_source=\(published.costProvenance.rawValue)")
        print("fixture_window_days=\(selected.historyDays)")
        print("fixture_window_tokens=\(selected.last30DaysTokens ?? 0)")
        print("fixture_window_cost_usd=\(selected.last30DaysCostUSD ?? 0)")
        print("fixture_window_source=\(selected.costProvenance.rawValue)")
    }

    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["CODEXBAR_LIVE_GROK_CATALOG_PROOF"] == "1",
        "Set CODEXBAR_LIVE_GROK_CATALOG_PROOF=1 to scan local Grok sessions."))
    func `writes redacted live Grok window proof`() async throws {
        let summary = try await GrokLocalSessionScanner.summarizeOffMainThread(
            env: ProcessInfo.processInfo.environment,
            lookbackDays: 365)
        let published = try #require(summary.toCostUsageTokenSnapshot(historyDays: 365))
        let store = Self.makeStore()
        store.publishTokenSnapshot(published, for: .grok)
        let remote = UsageSnapshot(
            primary: nil, secondary: nil, updatedAt: summary.scannedAt.addingTimeInterval(-60))

        print("live_full_source=\(published.costProvenance.rawValue)")
        for days in [1, 7, 30] {
            let selected = try #require(store.tokenSnapshotForLiveProviderConsumer(
                fromProviderSnapshot: remote, provider: .grok, historyDays: days))
            #expect(selected.historyDays == days)
            #expect(selected.updatedAt == published.updatedAt)
            if selected.daily.contains(where: { $0.costUSD != nil }) {
                try Self.verifySurfaces(selected, days: days)
            } else {
                #expect(selected.costProvenance == .unknown)
            }
            print("live_window_days=\(days)")
            print("live_window_tokens=\(selected.last30DaysTokens.map { String($0) } ?? "nil")")
            print("live_window_cost_usd=\(selected.last30DaysCostUSD.map { String($0) } ?? "nil")")
            print("live_window_source=\(selected.costProvenance.rawValue)")
            print("live_window_priced_days=\(selected.daily.count { $0.costUSD != nil })")
        }
    }

    private static func verifySurfaces(_ snapshot: CostUsageTokenSnapshot, days: Int) throws {
        let menu = try #require(UsageMenuCardView.Model.tokenUsageSection(
            provider: .grok,
            enabled: true,
            comparisonPeriodsEnabled: false,
            snapshot: snapshot,
            error: nil))
        let dashboard = SpendDashboardModel.build(
            inputs: [.init(provider: .grok, displayName: "Grok", snapshot: snapshot)],
            requestedDays: days,
            now: snapshot.updatedAt)
        let group = try #require(dashboard.groups.first)
        let row = try #require(group.providers.first)
        let disclosure = "Grok CLI-recorded spend, list price where unrecorded · not a bill."
        #expect(menu.hintLine == disclosure)
        #expect(row.costDisclaimer == disclosure)
        #expect(row.totalCost == snapshot.last30DaysCostUSD)
        #expect(group.provenance == snapshot.costProvenance)
        print("window_menu_disclosure=\(menu.hintLine ?? "nil")")
        print("window_dashboard_source=\(group.provenance.rawValue)")
    }

    private static func makeStore() -> UsageStore {
        let settings = testSettingsStore(suiteName: "GrokWindowProvenanceProofTests-\(UUID().uuidString)")
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }
}
