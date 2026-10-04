import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized, CostUsageClaudeCacheFixtures())
struct CostUsageClaudeReportWireTests {
    /// The former whole-array envelope is the byte/schema oracle.
    private struct LegacyEnvelope: Codable {
        var version = CostUsageClaudeReportMemo.persistedVersion
        var reportSemanticsVersion = CostUsageClaudeReportMemo.reportSemanticsVersion
        var sourceInventory: [String: CostUsageClaudeFileStamp] = [:]
        var reportKey: CostUsageClaudeReportMemoKey
        var report: CostUsageDailyReport
        var hourly: [CostUsageCodexPreviousReport.HourlyEntry]?
        var quotaSlices: [CostUsageCodexPreviousReport.QuotaSlice]?
        var hasWindowScopedRows: Bool? = true
    }

    @Test(arguments: [0, 1, 4096])
    func `memo bytes and decoded values match the whole-array envelope`(count: Int) throws {
        let fixture = try Fixture(count: count)
        defer { fixture.cleanup() }
        let expected = try fixture.encoded()
        fixture.store()
        #expect(try Data(contentsOf: fixture.memoURL) == expected)
        let loaded = try #require(fixture.load())
        #expect(loaded.reportKey == fixture.envelope.reportKey)
        #expect(loaded.sourceInventory == fixture.envelope.sourceInventory)
        #expect(loaded.hasWindowScopedRows)
        #expect(loaded.report.data == fixture.envelope.report.data)
        #expect(loaded.report.summary == fixture.envelope.report.summary)
        #expect(loaded.report.hourly == fixture.envelope.hourly?.map(\.hourlyValue))
        #expect(loaded.report.quotaSlices == fixture.envelope.quotaSlices?.map(\.timedValue))
        let stamp = CostUsageClaudeFileStamp.read(at: fixture.memoURL)
        fixture.store(report: loaded.report)
        #expect(CostUsageClaudeFileStamp.read(at: fixture.memoURL) == stamp)
    }

    @Test(arguments: ["missing", "null", "empty", "legacy-flags", "extreme-values"])
    func `legacy optional arrays and flags preserve defaults`(variant: String) throws {
        let fixture = try Fixture(count: 8)
        defer { fixture.cleanup() }
        var object = try #require(JSONSerialization.jsonObject(with: fixture.encoded()) as? [String: Any])
        switch variant {
        case "missing":
            object.removeValue(forKey: "quotaSlices")
            object.removeValue(forKey: "hourly")
            object.removeValue(forKey: "hasWindowScopedRows")
        case "null":
            object["quotaSlices"] = NSNull()
            object["hourly"] = NSNull()
            object["hasWindowScopedRows"] = NSNull()
        case "empty": object["quotaSlices"] = []
        case "legacy-flags":
            object["quotaSlices"] = [
                ["timestampUnixMs": 0, "totalTokens": 7, "costUSD": 0.25],
                ["timestampUnixMs": 1],
                ["timestampUnixMs": 2, "totalTokens": -1, "costUSD": -1],
                ["timestampUnixMs": 3, "tokensAreComplete": true, "costIsComplete": true],
            ]
        default:
            object["quotaSlices"] = [
                ["timestampUnixMs": Int64.max, "totalTokens": Int.max, "costUSD": Double.greatestFiniteMagnitude],
                ["timestampUnixMs": Int64.min, "totalTokens": Int.min, "costUSD": -0.0],
            ]
        }
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let oracle = try JSONDecoder().decode(LegacyEnvelope.self, from: bytes)
        try bytes.write(to: fixture.memoURL, options: .atomic)
        let loaded = try #require(fixture.load())
        #expect(loaded.report.quotaSlices == (oracle.quotaSlices ?? []).map(\.timedValue))
        #expect(loaded.report.hourly == (oracle.hourly ?? []).map(\.hourlyValue))
        #expect(loaded.hasWindowScopedRows == (oracle.hasWindowScopedRows == true))
    }

    @Test(arguments: ["null-entry", "missing-time", "overflow-time", "overflow-tokens", "bad-flag", "not-array"])
    func `malformed timed entries reject the entire envelope`(variant: String) throws {
        let fixture = try Fixture(count: 1)
        defer { fixture.cleanup() }
        var object = try #require(JSONSerialization.jsonObject(with: fixture.encoded()) as? [String: Any])
        switch variant {
        case "null-entry": object["quotaSlices"] = [NSNull()]
        case "missing-time": object["quotaSlices"] = [["totalTokens": 1]]
        case "overflow-time": object["quotaSlices"] = [["timestampUnixMs": UInt64.max]]
        case "overflow-tokens": object["quotaSlices"] = [["timestampUnixMs": 0, "totalTokens": UInt64.max]]
        case "bad-flag": object["quotaSlices"] = [["timestampUnixMs": 0, "tokensAreComplete": "true"]]
        default: object["quotaSlices"] = ["timestampUnixMs": 0]
        }
        let bytes = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(LegacyEnvelope.self, from: bytes) }
        try bytes.write(to: fixture.memoURL, options: .atomic)
        #expect(fixture.load() == nil)
    }

    @Test
    func `retained report survives atomic replacement and unchanged save does not rewrite`() throws {
        let fixture = try Fixture(count: 4096)
        defer { fixture.cleanup() }
        try fixture.encoded().write(to: fixture.memoURL, options: .atomic)
        let memo = CostUsageClaudeReportMemo()
        let loaded = try #require(memo.entry(provider: .claude, canonicalCachePath: fixture.cacheURL.path))
        let stamp = CostUsageClaudeFileStamp.read(at: fixture.memoURL)
        fixture.store(report: loaded.report)
        #expect(CostUsageClaudeFileStamp.read(at: fixture.memoURL) == stamp)
        try Data("invalid".utf8).write(to: fixture.memoURL, options: .atomic)
        #expect(loaded.report.quotaSlices == fixture.envelope.quotaSlices?.map(\.timedValue))
        #expect(memo.entry(provider: .claude, canonicalCachePath: fixture.cacheURL.path)?.report.quotaSlices
            == loaded.report.quotaSlices)
        #expect(fixture.load() == nil)
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity])
    func `unencodable timed entries leave the existing memo untouched`(cost: Double) throws {
        let fixture = try Fixture(count: 1)
        defer { fixture.cleanup() }
        fixture.store()
        let bytes = try Data(contentsOf: fixture.memoURL)
        let stamp = CostUsageClaudeFileStamp.read(at: fixture.memoURL)
        let slice = CostUsageTimedEntry(timestamp: Date(timeIntervalSince1970: 0), totalTokens: 1, costUSD: cost)
        var oracle = fixture.envelope
        oracle.report = CostUsageDailyReport(data: [], summary: nil, quotaSlices: [slice])
        oracle.quotaSlices = [CostUsageCodexPreviousReport.QuotaSlice(slice)]
        #expect(throws: EncodingError.self) { try JSONEncoder().encode(oracle) }
        fixture.store(report: oracle.report)
        #expect(try Data(contentsOf: fixture.memoURL) == bytes)
        #expect(CostUsageClaudeFileStamp.read(at: fixture.memoURL) == stamp)
    }

    @Test
    func `wire conversion materializes at most one entry at a time`() throws {
        let fixture = try Fixture(count: 4096)
        defer { fixture.cleanup() }
        let counter = WireCounter()
        let observer: @Sendable (Int) -> Void = { counter.record($0) }
        try CostUsageClaudeReportMemo.$observeWireEntriesForTesting.withValue(observer) {
            fixture.store()
            #expect(counter.snapshot() == [4096, 1])
            counter.reset()
            let loaded = try #require(fixture.load())
            #expect(loaded.report.quotaSlices.count == 4096)
            #expect(counter.snapshot() == [4096, 1])
        }
    }

    private final class WireCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var peak = 0

        func record(_ count: Int) {
            self.lock.withLock {
                self.calls += 1
                self.peak = max(self.peak, count)
            }
        }

        func snapshot() -> [Int] {
            self.lock.withLock { [self.calls, self.peak] }
        }

        func reset() {
            self.lock.withLock {
                self.calls = 0
                self.peak = 0
            }
        }
    }

    private struct Fixture {
        let root: URL
        let cacheURL: URL
        let memoURL: URL
        let envelope: LegacyEnvelope

        init(count: Int) throws {
            self.root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            self.cacheURL = self.root.appendingPathComponent("claude-v6.json")
            self.memoURL = CostUsageClaudeReportMemo.reportMemoFileURL(cacheFileURL: self.cacheURL)
            var slices: [CostUsageTimedEntry] = []
            slices.reserveCapacity(count)
            for index in 0..<count {
                let seconds = 1_780_000_000.0 + Double(index) / 1000.0
                let tokens: Int? = index % 3 == 0 ? nil : index
                let cost: Double? = index % 5 == 0 ? nil : Double(index) / 100.0
                slices.append(CostUsageTimedEntry(
                    timestamp: Date(timeIntervalSince1970: seconds),
                    totalTokens: tokens,
                    costUSD: cost,
                    tokensAreComplete: index % 7 != 0,
                    costIsComplete: index % 11 != 0))
            }
            let hourly = [CostUsageHourlyEntry(
                hour: Date(timeIntervalSince1970: 1_780_000_000), totalTokens: 7, costUSD: nil)]
            let report = CostUsageDailyReport(data: [], summary: nil, hourly: hourly, quotaSlices: slices)
            self.envelope = LegacyEnvelope(
                reportKey: CostUsageClaudeReportMemoKey(
                    provider: .claude,
                    providerFilter: "fixture",
                    sinceKey: "2026-01-01",
                    untilKey: "2026-10-04",
                    scanSinceKey: "2026-01-01",
                    scanUntilKey: "2026-10-04",
                    timeZoneIdentifier: "UTC",
                    roots: [self.root.path],
                    cacheArtifactStamp: nil,
                    pricingArtifactStamp: nil),
                report: report,
                hourly: hourly.map(CostUsageCodexPreviousReport.HourlyEntry.init),
                quotaSlices: slices.map(CostUsageCodexPreviousReport.QuotaSlice.init))
        }

        func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(self.envelope)
        }

        func store(report: CostUsageDailyReport? = nil) {
            CostUsageClaudeReportMemo().store(
                provider: .claude,
                canonicalCachePath: self.cacheURL.path,
                sourceInventory: self.envelope.sourceInventory,
                reportKey: self.envelope.reportKey,
                report: report ?? self.envelope.report,
                hasWindowScopedRows: true)
        }

        func load() -> CostUsageClaudeReportMemo.Entry? {
            CostUsageClaudeReportMemo().entry(provider: .claude, canonicalCachePath: self.cacheURL.path)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: self.root)
        }
    }
}
