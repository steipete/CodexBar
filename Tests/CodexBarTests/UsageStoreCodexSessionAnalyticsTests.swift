import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct UsageStoreCodexSessionAnalyticsTests {
    @Test
    func `store bootstraps analytics snapshot from persisted index`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let startedAt = try env.makeLocalNoon(year: 2026, month: 3, day: 26)
        _ = try env.writeCodexSessionFile(
            day: startedAt,
            filename: "rollout-bootstrap.jsonl",
            contents: self.sessionJSONL(
                id: "bootstrap-session",
                startedAt: startedAt,
                userMessage: "Bootstrap session",
                items: []))

        let indexer = CodexSessionAnalyticsIndexer(
            env: ["CODEX_HOME": env.codexHomeRoot.path],
            cacheRoot: env.cacheRoot)
        _ = try indexer.refreshIndex(existing: nil, now: startedAt)

        let store = self.makeStore()
        store.codexSessionAnalyticsIndexer = indexer
        store.bootstrapCodexSessionAnalyticsCache()

        #expect(store.codexSessionAnalytics?.sessions.first?.id == "bootstrap-session")
        #expect(store.codexSessionAnalyticsStatusText().contains("Updated"))
    }

    @Test
    func `request refresh keeps cached snapshot while background refresh updates it`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let oldStartedAt = try env.makeLocalNoon(year: 2026, month: 3, day: 27)
        _ = try env.writeCodexSessionFile(
            day: oldStartedAt,
            filename: "rollout-old.jsonl",
            contents: self.sessionJSONL(
                id: "old-session",
                startedAt: oldStartedAt,
                userMessage: "Old session",
                items: []))

        let indexer = CodexSessionAnalyticsIndexer(
            env: ["CODEX_HOME": env.codexHomeRoot.path],
            cacheRoot: env.cacheRoot)
        _ = try indexer.refreshIndex(existing: nil, now: oldStartedAt)

        let store = self.makeStore()
        store.codexSessionAnalyticsIndexer = indexer
        store.bootstrapCodexSessionAnalyticsCache()
        #expect(store.codexSessionAnalytics?.sessions.first?.id == "old-session")

        let newStartedAt = oldStartedAt.addingTimeInterval(3600)
        _ = try env.writeCodexSessionFile(
            day: newStartedAt,
            filename: "rollout-new.jsonl",
            contents: self.sessionJSONL(
                id: "new-session",
                startedAt: newStartedAt,
                userMessage: "New session",
                items: []))

        store.requestCodexSessionAnalyticsRefreshIfStale(reason: "test interaction")
        #expect(store.codexSessionAnalytics?.sessions.first?.id == "old-session")

        await store.codexSessionAnalyticsRefreshTask?.value

        #expect(store.codexSessionAnalytics?.sessions.first?.id == "new-session")
        #expect(store.codexSessionAnalyticsIsRefreshing == false)
        #expect(store.codexSessionAnalyticsDirty == false)
    }

    @Test
    func `watcher event marks analytics dirty without starting refresh while app is inactive`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let startedAt = try env.makeLocalNoon(year: 2026, month: 3, day: 28)
        _ = try env.writeCodexSessionFile(
            day: startedAt,
            filename: "rollout-dirty.jsonl",
            contents: self.sessionJSONL(
                id: "dirty-session",
                startedAt: startedAt,
                userMessage: "Dirty session",
                items: []))

        let indexer = CodexSessionAnalyticsIndexer(
            env: ["CODEX_HOME": env.codexHomeRoot.path],
            cacheRoot: env.cacheRoot)
        _ = try indexer.refreshIndex(existing: nil, now: startedAt)

        let store = self.makeStore()
        store.codexSessionAnalyticsIndexer = indexer
        store.bootstrapCodexSessionAnalyticsCache()

        store.codexSessionAnalyticsDirty = false
        store.handleCodexSessionAnalyticsWatcherEvent()

        #expect(store.codexSessionAnalyticsDirty == true)
        #expect(store.codexSessionAnalyticsRefreshTask == nil)
    }
}

extension UsageStoreCodexSessionAnalyticsTests {
    private func makeStore() -> UsageStore {
        let suite = "UsageStoreCodexSessionAnalyticsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false

        return UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
    }

    private func sessionJSONL(
        id: String,
        startedAt: Date,
        userMessage: String,
        items: [[String: Any]]) throws -> String
    {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var lines: [String] = []
        try lines.append(self.jsonLine([
            "timestamp": formatter.string(from: startedAt),
            "type": "session_meta",
            "payload": [
                "id": id,
                "timestamp": formatter.string(from: startedAt),
            ],
        ]))
        try lines.append(self.jsonLine([
            "timestamp": formatter.string(from: startedAt.addingTimeInterval(0.1)),
            "type": "event_msg",
            "payload": [
                "type": "user_message",
                "message": userMessage,
            ],
        ]))
        try lines.append(contentsOf: items.map(self.jsonLine(_:)))
        return lines.joined(separator: "\n") + "\n"
    }

    private func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try #require(String(bytes: data, encoding: .utf8))
    }
}
