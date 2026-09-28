import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct GrokBillingFailurePublicationTests {
    @Test(arguments: ["missing", "persisted", "live"])
    func `billing outages publish local tokens while preserving cached quota`(prior: String) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-outage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let session = home.appendingPathComponent("sessions/project/session")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let signals = session.appendingPathComponent("signals.json")
        try Data(#"{"totalTokensBeforeCompaction":1,"contextTokensUsed":0,"primaryModelId":"example-model"}"#.utf8)
            .write(to: signals)
        let env = ["GROK_HOME": home.path]
        let oldTokens = GrokLocalSessionScanner.summarize(env: env).toCostUsageTokenSnapshot(historyDays: 30)
        let quota = UsageSnapshot(
            primary: RateWindow(usedPercent: 29, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            costUsage: oldTokens,
            updatedAt: Date().addingTimeInterval(-3600))
        let settings = testSettingsStore(
            suiteName: "GrokBillingFailurePublicationTests",
            userDefaults: InMemoryUserDefaults(),
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { false }))
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        let metadata = try #require(ProviderRegistry.shared.metadata[.grok])
        settings.setProviderEnabled(provider: .grok, metadata: metadata, enabled: true)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: env),
            browserDetection: BrowserDetection(
                homeDirectory: home.path, cacheTTL: 0, fileExists: { _ in false }, directoryContents: { _ in [] }),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: env)
        if prior != "missing" {
            let restored = prior == "persisted"
                ? try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(quota)) : quota
            store.snapshots[.grok] = restored
            store.installProviderDerivedTokenSnapshot(from: restored, for: .grok)
        }
        store._test_providerFetchOutcomeOverride = { _ in
            ProviderFetchOutcome(result: .failure(URLError(.notConnectedToInternet)), attempts: [])
        }

        for tokens in [42, 85] {
            try Data("""
            {"totalTokensBeforeCompaction":\(tokens - 2),"contextTokensUsed":2,"primaryModelId":"example-model"}
            """.utf8).write(to: signals)
            await store.refreshProvider(.grok, allowDisabled: true)

            if prior != "missing" {
                #expect(store.snapshot(for: .grok)?.primary == quota.primary)
                #expect(store.snapshot(for: .grok)?.updatedAt == quota.updatedAt)
                #expect(store.snapshot(for: .grok)?.costUsage?.last30DaysTokens == tokens)
            }
            let published = try #require(store.tokenSnapshot(for: .grok))
            #expect(published.last30DaysTokens == tokens)
            #expect(published.last30DaysCostUSD == nil)
            let request = await SpendDashboardSource.makeRequest(settings: settings, store: store, mode: .captureOnly)
            let history = try #require(request.capturedInputs.first { $0.provider == .grok }?.snapshot)
            #expect(history.last30DaysTokens == tokens)
            let model = SpendDashboardModel.build(
                inputs: request.capturedInputs, requestedDays: 30, now: history.updatedAt)
            let shared = try #require(ShareStatsBuilder.make(model: model))
            #expect(shared.providers.first { $0.provider == .grok }?.totalTokens == tokens)
            #expect(shared.providers.first { $0.provider == .grok }?.estimatedCost == nil)
        }
    }
}
