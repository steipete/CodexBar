import Foundation
import Testing
@testable import CodexBarCore

struct PiSessionCostV8UpgradeTests {
    @Test
    func `released v8 reparses a recent cache despite unchanged transcript metadata`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let fixture = try Self.seedReleasedV8(in: env)
        let replacement = try Self.transcript(in: env, day: fixture.day, input: 20)
        #expect(Int64(replacement.utf8.count) == fixture.size)
        try replacement.write(to: fixture.sessionURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.modifiedAt],
            ofItemAtPath: fixture.sessionURL.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.sessionURL.path)
        #expect(try #require((attributes[.size] as? NSNumber)?.int64Value) == fixture.size)
        let modifiedAt = try #require(attributes[.modificationDate] as? Date)
        #expect(Int64(modifiedAt.timeIntervalSince1970 * 1000) ==
            Int64(fixture.modifiedAt.timeIntervalSince1970 * 1000))
        #expect(Self.cachedReport(fixture, now: fixture.day.addingTimeInterval(1)) == nil)

        let counter = PiV8UpgradeParseCounter()
        let observer: @Sendable () -> Void = { counter.increment() }
        let now = fixture.day.addingTimeInterval(1)
        let result = try PiSessionCostScanner.$sessionParseObserverForTesting.withValue(observer) {
            try Self.scan(fixture, now: now)
        }

        #expect(counter.value == 1)
        #expect(result.isComplete)
        #expect(result.report.summary?.totalTokens == 25)
        #expect(result.lastScanAt == now)
        #expect(result.scopeFingerprint == PiSessionCostScanner.scopeFingerprint(options: fixture.options))
        let rebuilt = PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)
        #expect(rebuilt.version == 9)
        #expect(rebuilt.lastScanUnixMs == Int64(now.timeIntervalSince1970 * 1000))
        #expect(Set(rebuilt.files.keys) == [Self.canonicalPath(fixture.sessionURL)])
        #expect(rebuilt.files.values.first?.parsedBytes == fixture.size)
        #expect(try Data(contentsOf: fixture.cacheURL) == fixture.cacheBytes)
        #expect(Self.cachedReport(fixture, now: now)?.report.summary?.totalTokens == 25)
    }

    @Test
    func `released v8 stays untouched while a configured root is unavailable and rebuilds on recovery`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let fixture = try Self.seedReleasedV8(in: env)
        let offlineRoot = env.root.appendingPathComponent("temporarily-offline", isDirectory: true)
        try FileManager.default.moveItem(at: env.piSessionsRoot, to: offlineRoot)
        let v9URL = PiSessionCostCacheIO.cacheFileURL(cacheRoot: env.cacheRoot)
        let failedAt = fixture.day.addingTimeInterval(1)
        #expect(Self.cachedReport(fixture, now: failedAt) == nil)

        let unavailable = try Self.scan(fixture, now: failedAt)
        #expect(!unavailable.isComplete)
        #expect(unavailable.report.data.isEmpty)
        #expect(unavailable.report.summary == nil)
        #expect(unavailable.lastScanAt == nil)
        #expect(unavailable.scopeFingerprint == nil)
        #expect(!FileManager.default.fileExists(atPath: v9URL.path))
        #expect(try Data(contentsOf: fixture.cacheURL) == fixture.cacheBytes)
        #expect(Self.cachedReport(fixture, now: failedAt) == nil)

        try FileManager.default.moveItem(at: offlineRoot, to: env.piSessionsRoot)
        let recoveredAt = fixture.day.addingTimeInterval(2)
        let recovered = try Self.scan(fixture, now: recoveredAt)
        #expect(recovered.isComplete)
        #expect(recovered.report.summary?.totalTokens == 15)
        #expect(recovered.lastScanAt == recoveredAt)
        #expect(recovered.scopeFingerprint == PiSessionCostScanner.scopeFingerprint(options: fixture.options))
        #expect(FileManager.default.fileExists(atPath: v9URL.path))
        #expect(try Data(contentsOf: fixture.cacheURL) == fixture.cacheBytes)
        let hydrated = try #require(Self.cachedReport(fixture, now: recoveredAt.addingTimeInterval(1)))
        #expect(hydrated.report.summary?.totalTokens == 15)
        #expect(hydrated.lastScanAt == recoveredAt)
        #expect(hydrated.scopeFingerprint == recovered.scopeFingerprint)
    }

    @Test(arguments: [false, true])
    func `released v8 root A is never attributed to replacement root B`(incompleteFirst: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let fixture = try Self.seedReleasedV8(in: env)
        let rootB = env.root.appendingPathComponent("replacement-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        let sessionB = rootB.appendingPathComponent(fixture.sessionURL.lastPathComponent)
        try Self.transcript(in: env, day: fixture.day, input: 30)
            .write(to: sessionB, atomically: true, encoding: .utf8)
        var optionsB = fixture.options
        optionsB.piSessionsRoot = rootB
        let expectedScopeB = PiSessionCostScanner.scopeFingerprint(options: optionsB)
        #expect(Self.cachedReport(fixture, now: fixture.day, options: optionsB) == nil)

        if incompleteFirst {
            let malformedURL = rootB.appendingPathComponent("2026-09-19T12-00-00-000Z_malformed.jsonl")
            try "{malformed}\n".write(to: malformedURL, atomically: true, encoding: .utf8)
            let incomplete = try Self.scan(fixture, now: fixture.day.addingTimeInterval(1), options: optionsB)
            #expect(!incomplete.isComplete)
            #expect(incomplete.report.data.isEmpty)
            #expect(incomplete.report.summary == nil)
            #expect(incomplete.lastScanAt == nil)
            #expect(incomplete.scopeFingerprint == nil)
            #expect(!FileManager.default.fileExists(
                atPath: PiSessionCostCacheIO.cacheFileURL(cacheRoot: env.cacheRoot).path))
            #expect(try Data(contentsOf: fixture.cacheURL) == fixture.cacheBytes)
            #expect(Self.cachedReport(fixture, now: fixture.day, options: optionsB) == nil)
            try FileManager.default.removeItem(at: malformedURL)
        }

        let completedAt = fixture.day.addingTimeInterval(2)
        let result = try Self.scan(fixture, now: completedAt, options: optionsB)
        #expect(result.isComplete)
        #expect(result.report.summary?.totalTokens == 35)
        #expect(result.lastScanAt == completedAt)
        #expect(result.scopeFingerprint == expectedScopeB)
        let rebuilt = PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)
        #expect(Set(rebuilt.files.keys) == [Self.canonicalPath(sessionB)])
        #expect(rebuilt.files[Self.canonicalPath(fixture.sessionURL)] == nil)
        #expect(rebuilt.sessionRootsFingerprint == expectedScopeB)
        #expect(try Data(contentsOf: fixture.cacheURL) == fixture.cacheBytes)
        #expect(Self.cachedReport(fixture, now: completedAt, options: optionsB)?
            .report.summary?.totalTokens == 35)
        #expect(Self.cachedReport(fixture, now: completedAt) == nil)
    }

    private struct Fixture {
        let day: Date
        let sessionURL: URL
        let modifiedAt: Date
        let size: Int64
        let cacheURL: URL
        let cacheBytes: Data
        let options: PiSessionCostScanner.Options
    }

    private static func seedReleasedV8(in env: CostUsageTestEnvironment) throws -> Fixture {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let day = try #require(ISO8601DateFormatter().date(from: "2026-09-19T12:00:00Z"))
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day, calendar: calendar)
        let sessionURL = try env.writePiSessionFile(
            relativePath: "2026-09-19T12-00-00-000Z_upgrade.jsonl",
            contents: Self.transcript(in: env, day: day, input: 10))
        try FileManager.default.setAttributes([.modificationDate: day], ofItemAtPath: sessionURL.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: sessionURL.path)
        let modifiedAt = try #require(attributes[.modificationDate] as? Date)
        let size = try #require((attributes[.size] as? NSNumber)?.int64Value)

        // v0.62.0 (4b3ed1a2a49a) JSON shape. Do not encode today's structs with version 8:
        // the released artifact had no root fingerprint or unsupported-history provenance fields.
        let usage: [String: Any] = [
            "inputTokens": 10,
            "cacheReadTokens": 0,
            "cacheWriteTokens": 0,
            "outputTokens": 5,
            "totalTokens": 15,
            "costNanos": 100_000,
            "costSampleCount": 1,
            "usageSampleCount": 1,
        ]
        let contributions: [String: Any] = ["codex": [range.sinceKey: ["gpt-5.4": usage]]]
        let file: [String: Any] = [
            "mtimeUnixMs": Int64(modifiedAt.timeIntervalSince1970 * 1000),
            "size": size,
            "parsedBytes": size,
            "contributions": contributions,
            "unkeyedContributions": contributions,
            "entryUsages": [String: Any](),
        ]
        let object: [String: Any] = [
            "version": 8,
            "lastScanUnixMs": Int64(day.timeIntervalSince1970 * 1000),
            "scanSinceKey": range.scanSinceKey,
            "scanUntilKey": range.scanUntilKey,
            "timeZoneIdentifier": calendar.timeZone.identifier,
            "pricingKey": CostUsagePricingKey.codex(
                modelsDevArtifact: nil,
                formulaVersion: 2,
                parserHash: "865a444e01b818f1",
                modelsDevProviderIDs: CostUsagePricing.codexModelsDevProviderIDs.union(
                    Set(CostUsagePricing.claudeFirstPartyModelsDevProviderIDs)),
                customPricingFingerprint: CostUsageCustomPricing.empty.fingerprint),
            "daysByProvider": contributions,
            "files": [sessionURL.path: file],
        ]
        let cacheURL = env.cacheRoot
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("pi-sessions-v8.json")
        let cacheBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try cacheBytes.write(to: cacheURL)
        let options = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            calendar: calendar,
            refreshMinIntervalSeconds: 3600,
            environment: ["HOME": env.root.path])
        return Fixture(
            day: day,
            sessionURL: sessionURL,
            modifiedAt: modifiedAt,
            size: size,
            cacheURL: cacheURL,
            cacheBytes: cacheBytes,
            options: options)
    }

    private static func transcript(in env: CostUsageTestEnvironment, day: Date, input: Int) throws -> String {
        try env.jsonl([[
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "gpt-5.4",
                "usage": ["input": input, "output": 5, "totalTokens": input + 5],
            ],
        ]])
    }

    private static func scan(
        _ fixture: Fixture,
        now: Date,
        options: PiSessionCostScanner.Options? = nil) throws -> PiSessionCostScanner.DailyReportResult
    {
        try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .codex,
            since: fixture.day,
            until: fixture.day,
            now: now,
            options: options ?? fixture.options,
            checkCancellation: nil)
    }

    private static func cachedReport(
        _ fixture: Fixture,
        now: Date,
        options: PiSessionCostScanner.Options? = nil) -> PiSessionCostScanner.CachedDailyReportResult?
    {
        PiSessionCostScanner.loadCachedDailyReportResult(
            provider: .codex,
            since: fixture.day,
            until: fixture.day,
            now: now,
            cacheRoot: fixture.options.cacheRoot,
            calendar: fixture.options.calendar,
            options: options ?? fixture.options,
            allowEstablishedEmpty: true)
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

private final class PiV8UpgradeParseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        self.lock.withLock { self.count }
    }

    func increment() {
        self.lock.withLock { self.count += 1 }
    }
}
