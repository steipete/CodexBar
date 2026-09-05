import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct GrokOpenCodexUsageTests {
    private static let now = Date(timeIntervalSince1970: 1_787_270_400)
    private static let calendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")
    private static let pricing = CostUsageCustomPricing(
        entries: ["xai/grok-test": .init(input: 2, output: 10)], fingerprint: "grok-test")

    @Test func `mixed attempts attribute only reported OAuth usage without the parent total`() throws {
        let entry = try Self.entry(attempts: [
            Self.attempt(ordinal: 1),
            Self.attempt(ordinal: 2, source: "xai-api-key"),
            Self.attempt(ordinal: 3, provider: "openai"),
        ])
        let snapshot = try #require(Self.snapshots([entry, entry])[.grok])
        #expect(snapshot.last30DaysTokens == 5)
        #expect(snapshot.daily.first?.totalTokens == 5)
        #expect(snapshot.sessions.first?.totalTokens == 5)
        #expect(snapshot.costProvenance == .listPriceEstimate)
        #expect(snapshot.daily.first?.coverageCounts.priced == 0)
        #expect(snapshot.daily.first?.estimatedRequestCount == 1)
        let cost = try #require(snapshot.last30DaysCostUSD)
        #expect(abs(cost - 0.000026) < 0.000000000001)
    }

    @Test func `legacy unknown API key and malformed attempts do not enter the subscription`() throws {
        let rejected: [[String: Any]] = [
            Self.attempt(source: nil), Self.attempt(source: "oauth"), Self.attempt(source: "xai-api-key"),
            Self.attempt(provider: "custom"), Self.attempt(model: "openai/grok-test"),
            Self.attempt(changes: ["sendCount": 0]), Self.attempt(changes: ["locallyAnswered": true]),
            Self.attempt(changes: ["usageStatus": "estimated"]),
            Self.attempt(changes: ["usageStatus": "unreported"]),
            Self.attempt(changes: ["ordinal": true]), Self.attempt(changes: ["ordinal": 1.5]),
            Self.attempt(changes: ["sendCount": 1.5]),
        ]
        for attempt in rejected {
            #expect(try Self.snapshots([Self.entry(attempts: [attempt])])[.grok] == nil)
        }
        let forgedTop = try Self.entry(attempts: [], changes: ["credentialSource": "grok-oauth"])
        #expect(Self.snapshots([forgedTop])[.grok] == nil)
        let duplicates = try Self.entry(attempts: [Self.attempt(), Self.attempt()])
        #expect(Self.snapshots([duplicates])[.grok] == nil)
    }

    @Test func `latest request replaces earlier attribution before subscription grouping`() throws {
        let earlier = try Self.entry(attempts: [Self.attempt()])
        let latest = try Self.entry(attempts: [Self.attempt(source: "xai-api-key")])
        #expect(Self.snapshots([earlier, latest])[.grok] == nil)
    }

    @Test func `missing token classes and unknown model prices retain tokens without dollars`() throws {
        for attempt in [
            Self.attempt(changes: ["usage": ["totalTokens": 5]]),
            Self.attempt(model: "grok-fictional-unpriced"),
        ] {
            let snapshot = try #require(try Self.snapshots([Self.entry(attempts: [attempt])])[.grok])
            #expect(snapshot.last30DaysTokens == 5)
            #expect(snapshot.last30DaysCostUSD == nil)
            #expect(snapshot.daily.first?.unpricedRequestCount == 1)
            #expect(snapshot.daily.first?.estimatedRequestCount == 0)
        }
    }

    @Test func `attempt provenance survives cache reopen incremental append and v2 rebuild`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("usage.jsonl")
        let cache = root.appendingPathComponent("cache")
        let firstLine = try Self.line(attempts: [Self.attempt()]) + "\n"
        try Data(firstLine.utf8).write(to: log)
        let store = OpenCodexUsageStore(cacheRoot: cache)
        let first = try store.loadEntries(logURL: log)
        let reopened = OpenCodexUsageStore(cacheRoot: cache)
        let recorder = OpenCodexUsageParser.LogReadRecorder()
        let cached = try OpenCodexUsageStore.withLogReadRecorderForTesting(recorder) {
            try reopened.loadEntries(logURL: log)
        }
        #expect(cached == first)
        #expect(recorder.snapshot().bytesRead == 0)
        #expect(cached.first?.attempts.first?.credentialSource == .grokOAuth)

        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((Self.line(
            attempts: [Self.attempt(source: "xai-api-key")], changes: ["requestId": "api-key"]) + "\n").utf8))
        try handle.close()
        let appended = try reopened.loadEntries(logURL: log)
        #expect(appended.count == 2)
        #expect(Self.snapshots(appended)[.grok]?.last30DaysTokens == 5)

        // A pre-provenance cache must re-read the raw log even when file size and mtime are unchanged.
        var database: OpaquePointer?
        let path = cache.appendingPathComponent(OpenCodexUsageStore.databaseFilename).path
        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "PRAGMA user_version = 2", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        let rebuilt = try OpenCodexUsageStore(cacheRoot: cache).loadEntries(logURL: log)
        #expect(rebuilt == appended)
        #expect(Self.snapshots(rebuilt)[.grok]?.last30DaysTokens == 5)
    }

    @Test func `Grok merge preserves recorded and estimated coverage across date filters`() throws {
        let supplement = try #require(try Self.snapshots([Self.entry(attempts: [Self.attempt()])])[.grok])
        let yesterday = Self.now.addingTimeInterval(-86400)
        let nativeDay = CostUsageDailyReport.Entry(
            date: CostUsageLocalDay.key(from: yesterday, calendar: Self.calendar),
            inputTokens: 8,
            outputTokens: 2,
            totalTokens: 10,
            costUSD: 0.1,
            modelsUsed: nil,
            modelBreakdowns: nil,
            pricedRequestCount: 1)
        let native = CostUsageFetcher.tokenSnapshot(
            from: CostUsageDailyReport(data: [nativeDay], summary: nil),
            now: Self.now,
            historyDays: 7,
            calendar: Self.calendar,
            costProvenance: .vendorMetered)
        let merged = OpenCodexUsageFanOut.mergeSnapshots(
            native, supplement, now: Self.now, historyDays: 7, calendar: Self.calendar, provider: .grok)
        #expect(merged.last30DaysTokens == 15)
        #expect(merged.costProvenance == .mixed)
        #expect(GrokLocalSessionSummary.costProvenance(for: [nativeDay], fallback: merged.costProvenance)
            == .vendorMetered)
        #expect(GrokLocalSessionSummary.costProvenance(for: supplement.daily, fallback: merged.costProvenance)
            == .listPriceEstimate)
    }

    @Test func `dashboard publishes OAuth attempts only when the existing OpenCodex switch is on`() throws {
        let entry = try Self.entry(attempts: [Self.attempt()])
        for enabled in [false, true] {
            let config = SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: [UsageProvider.grok.rawValue],
                codexAccountIdentities: [],
                bucketTimeZoneIdentifier: "UTC",
                openCodexUsageLogsEnabled: enabled)
            let request = SpendDashboardLoadRequest(
                configuration: config,
                capturedInputs: [],
                unavailableSourceIDs: [],
                confirmedEmptySourceIDs: [],
                codexRequests: [],
                now: Self.now,
                force: false)
            let result = SpendDashboardSource.mergingOpenCodexInputsWithObservation(
                [],
                request: request,
                environment: ["OPENCODEX_HOME": "/synthetic/opencodex"],
                entryLoader: { _ in [entry] })
            #expect(result.inputs.count == (enabled ? 1 : 0))
            if enabled {
                #expect(result.inputs.first?.provider == .grok)
                #expect(result.inputs.first?.sourceKind == .openCodex)
                #expect(result.inputs.first?.snapshot.last30DaysTokens == 5)
            }
        }
    }

    @Test func `non Grok token only routes keep standalone zero and custom prices`() throws {
        for provider in ["opencode", "opencode-free"] {
            let entry = OpenCodexUsageEntry(
                requestID: "standalone-\(provider)",
                timestamp: Self.now,
                provider: provider,
                model: "deepseek-v4-flash-free",
                usageStatus: .reported,
                usage: OpenCodexTokenUsage(inputTokens: 3, outputTokens: 2, totalTokens: 5),
                totalTokens: 5)
            let freeCatalogJSON = """
            {"opencode":{"id":"opencode","models":{"deepseek-v4-flash-free":{
            "id":"deepseek-v4-flash-free","cost":{"input":0,"output":0}}}}}
            """
            let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(freeCatalogJSON.utf8))
            let free = OpenCodexUsageAggregator.snapshot(
                entries: [entry],
                now: Self.now,
                historyDays: 7,
                calendar: Self.calendar,
                modelsDevCatalog: catalog,
                customPricingOverlay: .empty)
            #expect(free.last30DaysCostUSD == 0)
            for inputRate in [0.0, 2.0] {
                let pricing = CostUsageCustomPricing(
                    entries: ["\(provider)/deepseek-v4-flash-free": .init(input: inputRate, output: inputRate)],
                    fingerprint: "standalone-\(inputRate)")
                let snapshot = OpenCodexUsageAggregator.snapshot(
                    entries: [entry],
                    now: Self.now,
                    historyDays: 7,
                    calendar: Self.calendar,
                    customPricing: pricing,
                    modelsDevCatalog: ModelsDevCatalog(providers: [:]))
                let cost = try #require(snapshot.last30DaysCostUSD)
                #expect(abs(cost - inputRate * 5 / 1_000_000) < 0.000000000001)
                #expect(Self.snapshots([entry]).isEmpty)
            }
        }
    }

    @Test func `captured producer ledger imports through the dashboard disk loader and cache`() throws {
        let fixture = try #require(Bundle.module.url(
            forResource: "usage", withExtension: "jsonl", subdirectory: "Fixtures/GrokOpenCodex"))
        let captured = try Data(contentsOf: fixture)
        let digest = SHA256.hash(data: captured).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "ef6d8758b40910f6e5993d5b5a105a2ad2834c6c1bd0565ab87b61cf091c4978")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("usage.jsonl")
        try captured.write(to: log)
        let proofNow = Date(timeIntervalSince1970: 1_788_597_900)
        let config = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [UsageProvider.grok.rawValue],
            codexAccountIdentities: [],
            bucketTimeZoneIdentifier: "UTC",
            openCodexUsageLogsEnabled: true)
        let request = SpendDashboardLoadRequest(
            configuration: config,
            capturedInputs: [],
            unavailableSourceIDs: [],
            confirmedEmptySourceIDs: [],
            codexRequests: [],
            now: proofNow,
            force: false)
        let cache = root.appendingPathComponent("cache")
        let imported = SpendDashboardSource.mergingOpenCodexInputsWithObservation(
            [], request: request, environment: ["OPENCODEX_HOME": root.path], cacheRoot: cache)
        let snapshot = try #require(imported.inputs.first?.snapshot)
        #expect(imported.inputs.count == 1)
        #expect(imported.inputs.first?.provider == .grok)
        #expect(snapshot.last30DaysTokens == 5)
        #expect(snapshot.daily.first?.inputTokens == 3)
        #expect(snapshot.daily.first?.outputTokens == 2)
        let dashboard = SpendDashboardModel.build(inputs: imported.inputs, requestedDays: 7, now: proofNow)
        #expect(dashboard.groups.first?.providers.first?.totalTokens == 5)
        let recorder = OpenCodexUsageParser.LogReadRecorder()
        let reopened = OpenCodexUsageStore.withLogReadRecorderForTesting(recorder) {
            SpendDashboardSource.mergingOpenCodexInputsWithObservation(
                [], request: request, environment: ["OPENCODEX_HOME": root.path], cacheRoot: cache)
        }
        #expect(reopened.inputs.first?.snapshot.last30DaysTokens == 5)
        #expect(recorder.snapshot().bytesRead == 0)
        // Keep the exact producer-written API-key line, without fabricating a replacement record.
        let text = try #require(String(data: captured, encoding: .utf8))
        let keyLine = try #require(text.split(separator: "\n").first { $0.contains("\"xai-api-key\"") })
        try Data((keyLine + "\n").utf8).write(to: log)
        let keyOnly = SpendDashboardSource.mergingOpenCodexInputsWithObservation(
            [], request: request, environment: ["OPENCODEX_HOME": root.path], cacheRoot: cache)
        #expect(keyOnly.inputs.isEmpty)
        print("producer_capture_sha256=\(digest)")
        print("producer_log_rows=2 total_reported_tokens=10 grok_oauth_tokens=5")
        print("producer_import_dashboard_tokens=5 cache_reopen_bytes=\(recorder.snapshot().bytesRead)")
        print("producer_api_key_only_subscription_rows=\(keyOnly.inputs.count)")
    }

    private static func snapshots(_ entries: [OpenCodexUsageEntry]) -> [UsageProvider: CostUsageTokenSnapshot] {
        OpenCodexUsageFanOut.snapshotsBySubscription(
            entries: entries, now: self.now, historyDays: 7, calendar: self.calendar, customPricing: self.pricing)
    }

    private static func attempt(
        ordinal: Int = 1,
        provider: String = "xai",
        model: String = "grok-test",
        source: String? = "grok-oauth",
        changes: [String: Any] = [:]) -> [String: Any]
    {
        var row: [String: Any] = [
            "ordinal": ordinal, "provider": provider, "model": model, "adapter": "openai-responses",
            "status": 200, "durationMs": 1, "sendCount": 1, "recoveryKinds": [], "usageStatus": "reported",
            "usage": ["inputTokens": 3, "outputTokens": 2, "totalTokens": 5], "totalTokens": 5,
        ]
        row["credentialSource"] = source
        row.merge(changes, uniquingKeysWith: { _, latest in latest })
        return row
    }

    private static func line(attempts: [[String: Any]], changes: [String: Any] = [:]) throws -> String {
        var row: [String: Any] = [
            "requestId": "ocx-mixed", "timestamp": self.now.timeIntervalSince1970 * 1000,
            "provider": "combo", "model": "combo/test", "usageStatus": "reported", "status": 200,
            "durationMs": 1, "totalTokens": 15000, "attempts": attempts,
        ]
        row.merge(changes, uniquingKeysWith: { _, latest in latest })
        return try #require(String(data: JSONSerialization.data(withJSONObject: row), encoding: .utf8))
    }

    private static func entry(attempts: [[String: Any]], changes: [String: Any] = [:]) throws -> OpenCodexUsageEntry {
        try #require(OpenCodexUsageParser.parseLine(self.line(attempts: attempts, changes: changes)))
    }
}
