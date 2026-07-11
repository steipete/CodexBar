import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct CursorWidgetSnapshotTests {
    @Test
    func `cursor widget preserves approximate selected range total and calendar range`() async throws {
        let now = Date(timeIntervalSince1970: 1_773_000_000)
        let range = CursorRecentRequestRange(
            start: now.addingTimeInterval(-3600),
            end: now)
        let request = CursorRecentRequest(
            timestamp: now.addingTimeInterval(-60),
            model: "gpt-5.5",
            tokens: 1000,
            requests: 1,
            requestCost: 1)
        let summary = CursorRangeUsageSummary(
            rangeKind: .billingCycle,
            range: range,
            tokens: 1000,
            requests: 1,
            weightedRequestCost: 1,
            requestCostSummary: CursorRequestCostSummary(
                exactUSD: nil,
                lowerBoundUSD: Decimal(string: "4.10"),
                upperBoundUSD: nil,
                containsApproximation: true),
            recentRequests: [request])
        let settings = Self.makeSettingsStore(suite: "CursorWidgetSnapshotTests-cycle")
        settings.cursorUsageRangeKind = .billingCycle
        let store = Self.makeUsageStore(settings: settings)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: nil,
                secondary: nil,
                cursorRangeSummaries: [summary],
                updatedAt: now),
            provider: .cursor)

        var captured: WidgetSnapshot?
        store._test_widgetSnapshotSaveOverride = { captured = $0 }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "cursor-range")
        await store.widgetSnapshotPersistTask?.value
        let entry = try #require(captured?.entries.first { $0.provider == .cursor })

        #expect(Self.encodedSnapshot(captured).contains("\"sessionCostText\":\"Approx. $4.10+\""))
        #expect(entry.cursorRequestRange?.label == "Cycle")
        #expect(entry.cursorRequestRange?.start == range.start)
        #expect(entry.cursorRequestRange?.end == range.end)
        #expect(entry.tokenUsage?.sessionTokens == 1000)
        #expect(entry.cursorRequestDetails?.first?.requestCost == 1)
    }

    @Test
    func `cursor widget preserves selected 30d range and row estimate`() async throws {
        let now = Date(timeIntervalSince1970: 1_773_000_000)
        let range = CursorRecentRequestRange(
            start: now.addingTimeInterval(-30 * 24 * 60 * 60),
            end: now)
        let request = CursorRecentRequest(
            timestamp: now.addingTimeInterval(-120),
            model: "gpt-5.5-extra-high",
            tokens: 1_000_000,
            requests: 1)
        let summary = CursorRangeUsageSummary(
            rangeKind: .last30Days,
            range: range,
            tokens: request.tokens,
            requests: request.requests,
            requestCostSummary: CursorRequestCostEstimator.summarizedEstimate(for: [request]),
            recentRequests: [request])
        let settings = Self.makeSettingsStore(suite: "CursorWidgetSnapshotTests-30d")
        settings.cursorUsageRangeKind = .last30Days
        let store = Self.makeUsageStore(settings: settings)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: nil,
                secondary: nil,
                cursorRangeSummaries: [summary],
                updatedAt: now),
            provider: .cursor)

        var captured: WidgetSnapshot?
        store._test_widgetSnapshotSaveOverride = { captured = $0 }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "cursor-range")
        await store.widgetSnapshotPersistTask?.value
        let entry = try #require(captured?.entries.first { $0.provider == .cursor })

        #expect(entry.cursorRequestRange?.label == "30d")
        #expect(entry.cursorRequestRange?.start == range.start)
        #expect(entry.cursorRequestRange?.end == range.end)
        #expect(entry.cursorRequestDetails?.first?.compactModel == "GPT-5.5 · extra-high")
        #expect(entry.cursorRequestDetails?.first?.estimateText?.hasPrefix("Approx.") == true)
    }

    private static func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private static func makeUsageStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
    }

    private static func encodedSnapshot(_ snapshot: WidgetSnapshot?) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(snapshot)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
