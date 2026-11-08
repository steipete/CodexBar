import Foundation
import Testing
@testable import CodexBarCore

struct PiSessionCostV9UpgradeTests {
    @Test
    func `released v9 cache is rebuilt once to add session metadata`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let fixture = try Self.seedReleasedArtifact(in: env, version: 9)

        let counter = PiBreakdownParseCounter()
        let observer: @Sendable () -> Void = { counter.increment() }
        let result = try PiSessionCostScanner.$sessionParseObserverForTesting.withValue(observer) {
            try Self.scan(fixture)
        }

        #expect(counter.value == 1)
        #expect(result.isComplete)
        #expect(result.report.summary?.totalTokens == 15)
        let rebuilt = PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)
        #expect(rebuilt.version == 10)
        let currentURL = PiSessionCostCacheIO.cacheFileURL(cacheRoot: env.cacheRoot)
        #expect(currentURL.lastPathComponent == "pi-sessions-v10.json")
        #expect(FileManager.default.fileExists(atPath: currentURL.path))
        #expect(try Data(contentsOf: fixture.cacheURL) == fixture.cacheBytes)
        let session = try #require(rebuilt.sessions["upgrade-session"])
        #expect(session.projectPath == "/Users/test/projects/alpha")
        #expect(session.title == "Refactor parser")
        #expect(result.sessions.map(\.title) == ["Refactor parser"])
        #expect(result.projects.map(\.path) == ["/Users/test/projects/alpha"])
    }

    @Test
    func `the same warm artifact at the current version is reused without reparsing`() throws {
        // Control for the upgrade test: the seed is a warm cache, so only the version forces the reparse.
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let fixture = try Self.seedReleasedArtifact(in: env, version: 10)

        let counter = PiBreakdownParseCounter()
        let observer: @Sendable () -> Void = { counter.increment() }
        let result = try PiSessionCostScanner.$sessionParseObserverForTesting.withValue(observer) {
            try Self.scan(fixture)
        }

        #expect(counter.value == 0)
        #expect(result.report.summary?.totalTokens == 15)
        #expect(result.isComplete)
        #expect(result.sessions.isEmpty)
        // Usage without session rows cannot partition the total, so details stay incomplete.
        #expect(!result.detailsAreComplete)
    }

    private struct Fixture {
        let day: Date
        let cacheURL: URL
        let cacheBytes: Data
        let options: PiSessionCostScanner.Options
    }

    private static func seedReleasedArtifact(in env: CostUsageTestEnvironment, version: Int) throws -> Fixture {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let day = try #require(ISO8601DateFormatter().date(from: "2026-09-19T12:00:00Z"))
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day, calendar: calendar)
        let sessionURL = try env.writePiSessionFile(
            relativePath: "2026-09-19T12-00-00-000Z_upgrade.jsonl",
            contents: env.jsonl([
                [
                    "type": "session",
                    "version": 3,
                    "id": "upgrade-session",
                    "timestamp": env.isoString(for: day),
                    "cwd": "/Users/test/projects/alpha",
                ],
                ["type": "session_info", "name": "Refactor parser"],
                [
                    "type": "message",
                    "id": "turn-1",
                    "timestamp": env.isoString(for: day),
                    "message": [
                        "role": "assistant",
                        "provider": "openai-codex",
                        "model": "gpt-5.4",
                        "usage": ["input": 10, "output": 5, "totalTokens": 15],
                    ],
                ],
            ]))
        try FileManager.default.setAttributes([.modificationDate: day], ofItemAtPath: sessionURL.path)
        let canonicalPath = sessionURL.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
        let attributes = try FileManager.default.attributesOfItem(atPath: canonicalPath)
        let modifiedAt = try #require(attributes[.modificationDate] as? Date)
        let size = try #require((attributes[.size] as? NSNumber)?.int64Value)
        let device = try #require(attributes[.systemNumber] as? NSNumber)
        let inode = try #require(attributes[.systemFileNumber] as? NSNumber)
        let options = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            calendar: calendar,
            refreshMinIntervalSeconds: 3600,
            environment: ["HOME": env.root.path])

        // Released v9 JSON shape, before session metadata existed. Do not encode today's structs.
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
            "fileIdentity": "\(device):\(inode)",
            "sessionID": "upgrade-session",
            "contributions": contributions,
            "unkeyedContributions": [String: Any](),
            "entryUsages": [
                "turn-1": [
                    "providerRawValue": "codex",
                    "dayKey": range.sinceKey,
                    "modelName": "gpt-5.4",
                    "usage": usage,
                ],
            ],
            "unsupportedAssistantDayKeys": [String](),
            "hasUndatedUnsupportedAssistant": false,
        ]
        var object: [String: Any] = [
            "version": version,
            "lastScanUnixMs": Int64(day.timeIntervalSince1970 * 1000),
            "scanSinceKey": range.scanSinceKey,
            "scanUntilKey": range.scanUntilKey,
            "timeZoneIdentifier": calendar.timeZone.identifier,
            // Matches the scanner's current pricing inputs (cost formula version 5).
            "pricingKey": CostUsagePricingKey.codex(
                modelsDevArtifact: ModelsDevCache.load(now: day, cacheRoot: env.cacheRoot).artifact,
                formulaVersion: 5,
                parserHash: CodexParserHash.value,
                modelsDevProviderIDs: CostUsagePricing.codexModelsDevProviderIDs.union(
                    Set(CostUsagePricing.claudeFirstPartyModelsDevProviderIDs + ["amazon-bedrock"])),
                customPricingFingerprint: CostUsageCustomPricing.load().fingerprint),
            "sessionRootsFingerprint": PiSessionCostScanner.scopeFingerprint(options: options),
            "daysByProvider": contributions,
            "files": [canonicalPath: file],
        ]
        if version >= 10 {
            object["sessions"] = [String: Any]()
        }
        let cacheURL = env.cacheRoot
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("pi-sessions-v\(version).json")
        let cacheBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try cacheBytes.write(to: cacheURL)
        return Fixture(day: day, cacheURL: cacheURL, cacheBytes: cacheBytes, options: options)
    }

    private static func scan(_ fixture: Fixture) throws -> PiSessionCostScanner.DailyReportResult {
        try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .pi,
            since: fixture.day,
            until: fixture.day,
            now: fixture.day.addingTimeInterval(1),
            options: fixture.options,
            checkCancellation: nil)
    }
}
