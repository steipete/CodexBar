import Foundation
import Testing
@testable import CodexBarCore

struct OpenCodexUsagePricingTests {
    private static let now = Date(timeIntervalSince1970: 1_787_270_400)
    private static let calendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")

    @Test func `application overlay preserves bare model precedence and cached token accounting`() throws {
        let entry = Self.entry(provider: "openai", model: "gpt-5.4", cached: true)
        let bare = CostUsageCustomPricing.Rates(input: 3, output: 4, cacheRead: 1, cacheWrite: 2)
        let qualified = CostUsageCustomPricing.Rates(input: 9, output: 9, cacheRead: 9, cacheWrite: 9)
        let cases: [([String: CostUsageCustomPricing.Rates], Double)] = [
            (["gpt-5.4": bare], 0.000030),
            (["gpt-5.4": bare, "openai/gpt-5.4": qualified], 0.000030),
            (["openai/gpt-5.4": qualified], 0.000108),
            (["gpt-5.4": .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)], 0),
        ]
        for (entries, expected) in cases {
            let snapshot = Self.snapshot(entry, overlay: .init(entries: entries, fingerprint: "overlay"))
            let cost = try #require(snapshot.last30DaysCostUSD)
            #expect(abs(cost - expected) < 0.000000000001)
        }
    }

    @Test func `incomplete bare application override stays unknown ahead of qualified and catalog prices`() {
        let snapshot = Self.snapshot(
            Self.entry(provider: "openai", model: "gpt-5.4"),
            overlay: .init(entries: [
                "gpt-5.4": .init(input: 3),
                "openai/gpt-5.4": .init(input: 9, output: 9),
            ], fingerprint: "missing-output"))
        #expect(snapshot.last30DaysTokens == 5)
        #expect(snapshot.last30DaysCostUSD == nil)
    }

    @Test func `snapshot custom prices keep precedence over the application overlay`() throws {
        let snapshot = Self.snapshot(
            Self.entry(provider: "openai", model: "gpt-5.4"),
            pricing: .init(entries: ["gpt-5.4": .init(input: 2, output: 2)], fingerprint: "snapshot"),
            overlay: .init(entries: ["gpt-5.4": .init(input: 9, output: 9)], fingerprint: "application"))
        let cost = try #require(snapshot.last30DaysCostUSD)
        #expect(abs(cost - 0.000010) < 0.000000000001)
    }

    @Test func `standalone xai custom estimates survive cache loading without subscription attribution`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("usage.jsonl")
        let cache = root.appendingPathComponent("cache")
        let pricingFile = root.appendingPathComponent("custom-pricing.json")
        let model = "grok-fictional-priced"
        let timestamp = Int(Self.now.timeIntervalSince1970 * 1000)
        for source in ["", "xai-api-key"] {
            let attempts = source.isEmpty ? "[]" : """
            [{"ordinal":1,"provider":"xai","model":"\(model)","sendCount":1,\
            "credentialSource":"\(source)","usageStatus":"reported",\
            "usage":{"inputTokens":3,"outputTokens":2,"totalTokens":5}}]
            """
            try """
            {"requestId":"standalone","timestamp":\(timestamp),"provider":"xai","model":"\(model)",\
            "usageStatus":"reported","usage":{"inputTokens":3,"outputTokens":2,"totalTokens":5},\
            "attempts":\(attempts)}

            """.write(to: log, atomically: true, encoding: .utf8)
            for key in [model, "xai/\(model)"] {
                for rate in [0.0, 2.0] {
                    try """
                    {"\(key)":{"input":\(rate),"output":\(rate)}}
                    """.write(to: pricingFile, atomically: true, encoding: .utf8)
                    let pricing = CostUsageCustomPricing.load(fileURL: pricingFile)
                    let store = OpenCodexUsageStore(cacheRoot: cache)
                    let entries = try store.loadEntries(logURL: log)
                    let entry = try #require(entries.first)
                    #expect(entry.credentialSource == nil)
                    #expect(OpenCodexUsageFanOut.snapshotsBySubscription(
                        entries: entries,
                        now: Self.now,
                        historyDays: 7,
                        calendar: Self.calendar,
                        customPricing: pricing).isEmpty)
                    let loaded = try store.loadSnapshot(
                        logURL: log,
                        now: Self.now,
                        historyDays: 7,
                        calendar: Self.calendar,
                        customPricing: pricing)
                    let application = Self.snapshot(entry, overlay: pricing)
                    for snapshot in [loaded, application] {
                        let cost = try #require(snapshot.last30DaysCostUSD)
                        #expect(abs(cost - rate * 5 / 1_000_000) < 0.000000000001)
                        #expect(snapshot.costProvenance == .listPriceEstimate)
                    }
                    #expect(Self.snapshot(entry).last30DaysCostUSD == nil)
                }
            }
        }
    }

    private static func entry(provider: String, model: String, cached: Bool = false) -> OpenCodexUsageEntry {
        OpenCodexUsageEntry(
            requestID: "pricing",
            timestamp: self.now,
            provider: provider,
            model: model,
            usageStatus: .reported,
            usage: OpenCodexTokenUsage(
                inputTokens: cached ? 10 : 3,
                outputTokens: 2,
                cacheReadInputTokens: cached ? 3 : nil,
                cacheCreationInputTokens: cached ? 2 : nil,
                totalTokens: cached ? 12 : 5),
            totalTokens: cached ? 12 : 5)
    }

    private static func snapshot(
        _ entry: OpenCodexUsageEntry,
        pricing: CostUsageCustomPricing = .empty,
        overlay: CostUsageCustomPricing = .empty) -> CostUsageTokenSnapshot
    {
        OpenCodexUsageAggregator.snapshot(
            entries: [entry],
            now: self.now,
            historyDays: 7,
            calendar: self.calendar,
            customPricing: pricing,
            modelsDevCatalog: ModelsDevCatalog(providers: [:]),
            customPricingOverlay: overlay)
    }
}
