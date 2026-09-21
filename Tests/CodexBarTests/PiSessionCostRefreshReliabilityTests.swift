import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct PiSessionCostRefreshReliabilityTests {
    @Test
    func `an incomplete catalog reprice retains the previous report until every source can be repriced`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 10)
        let contents = try env.jsonl([
            self.row(env, day, input: 150_000, model: "gpt-5.6-sol"),
        ])
        _ = try env.writePiSessionFile(relativePath: "a-good.jsonl", contents: contents)
        let badFile = try env.writePiSessionFile(relativePath: "b-bad.jsonl", contents: contents)
        var options = try self.options(env)
        options.refreshMinIntervalSeconds = 3600
        #expect(try ModelsDevCache.save(
            catalog: Self.catalog(inputCostPerMillion: 4), fetchedAt: day, cacheRoot: env.cacheRoot))
        let original = try self.scan(day, now: day, options: options)
        #expect(original.isComplete)
        #expect(original.report.summary?.totalTokens == 300_000)
        let originalCost = try #require(original.report.summary?.totalCostUSD)
        #expect(abs(originalCost - 1.2) < 0.000001)
        let cacheURL = PiSessionCostCacheIO.cacheFileURL(cacheRoot: env.cacheRoot)
        let savedBytes = try Data(contentsOf: cacheURL)
        let oldPricingKey = PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot).pricingKey

        #expect(try ModelsDevCache.save(
            catalog: Self.catalog(inputCostPerMillion: 8),
            fetchedAt: day.addingTimeInterval(1),
            cacheRoot: env.cacheRoot))
        try self.append("{broken}\n", to: badFile)
        let incomplete = try self.scan(day, now: day.addingTimeInterval(2), options: options)
        #expect(!incomplete.isComplete)
        #expect(incomplete.report.data == original.report.data)
        #expect(incomplete.report.summary == original.report.summary)
        let retainedCost = try #require(incomplete.report.summary?.totalCostUSD)
        #expect(abs(retainedCost - 1.2) < 0.000001)
        #expect(incomplete.lastScanAt == original.lastScanAt)
        #expect(incomplete.scopeFingerprint == original.scopeFingerprint)
        #expect(try Data(contentsOf: cacheURL) == savedBytes)
        #expect(PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot).pricingKey == oldPricingKey)

        try contents.write(to: badFile, atomically: true, encoding: .utf8)
        let recoveredAt = day.addingTimeInterval(3)
        let recovered = try self.scan(day, now: recoveredAt, options: options)
        #expect(recovered.isComplete)
        #expect(recovered.report.summary?.totalTokens == 300_000)
        let recoveredCost = try #require(recovered.report.summary?.totalCostUSD)
        #expect(abs(recoveredCost - 2.4) < 0.000001)
        #expect(recovered.lastScanAt == recoveredAt)
        #expect(recovered.scopeFingerprint == original.scopeFingerprint)
        #expect(PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot).pricingKey != oldPricingKey)
    }

    @Test(arguments: [false, true])
    func `replacement after bytes are read cannot advance full or incremental cache freshness`(
        incremental: Bool) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let options = try self.options(env)
        let first = try env.jsonl([self.row(env, day, input: 10, output: 5)])
        let changedFirst = try env.jsonl([self.row(env, day, input: 90, output: 5)])
        #expect(first.utf8.count == changedFirst.utf8.count)
        let file = try env.writePiSessionFile(relativePath: "during-read.jsonl", contents: first)
        try FileManager.default.setAttributes([.modificationDate: day], ofItemAtPath: file.path)
        let original = try self.scan(day, now: day, options: options)
        #expect(original.isComplete)
        #expect(original.report.summary?.totalTokens == 15)
        let cacheURL = PiSessionCostCacheIO.cacheFileURL(cacheRoot: env.cacheRoot)
        let savedBytes = try Data(contentsOf: cacheURL)
        let originalIdentity = try #require(PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)
            .files.values.first?.fileIdentity)

        let suffix = incremental ? try env.jsonl([self.row(env, day, input: 20, output: 10)]) : ""
        if incremental { try self.append(suffix, to: file) }
        try FileManager.default.setAttributes([.modificationDate: day], ofItemAtPath: file.path)
        let replacement = Data((changedFirst + suffix).utf8)
        #expect(try Data(contentsOf: file).count == replacement.count)
        let trigger = PiCostReadReplacement(file: file, replacement: replacement, modifiedAt: day)
        let observer: @Sendable () -> Void = { trigger.arm() }
        var raceOptions = options
        raceOptions.forceRescan = !incremental
        let raced = try PiSessionCostScanner.$sessionParseObserverForTesting.withValue(observer) {
            try PiSessionCostScanner.loadDailyReportResultCancellable(
                provider: .pi,
                since: day,
                until: day,
                now: day.addingTimeInterval(1),
                options: raceOptions,
                checkCancellation: { try trigger.check() })
        }
        #expect(trigger.didReplace)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let device = try #require(attributes[.systemNumber] as? NSNumber).uint64Value
        let inode = try #require(attributes[.systemFileNumber] as? NSNumber).uint64Value
        #expect(originalIdentity != "\(device):\(inode)")
        #expect(try #require(attributes[.size] as? NSNumber).intValue == replacement.count)
        let modified = try #require(attributes[.modificationDate] as? Date)
        #expect(Int64(modified.timeIntervalSince1970 * 1000) == Int64(day.timeIntervalSince1970 * 1000))
        #expect(!raced.isComplete)
        #expect(raced.report.data == original.report.data)
        #expect(raced.report.summary == original.report.summary)
        #expect(raced.lastScanAt == original.lastScanAt)
        #expect(raced.scopeFingerprint == original.scopeFingerprint)
        #expect(try Data(contentsOf: cacheURL) == savedBytes)

        let recovered = try self.scan(day, now: day.addingTimeInterval(2), options: options)
        #expect(recovered.isComplete)
        #expect(recovered.report.summary?.totalTokens == (incremental ? 125 : 95))
        #expect(recovered.lastScanAt == day.addingTimeInterval(2))
    }

    private func options(_ env: CostUsageTestEnvironment) throws -> PiSessionCostScanner.Options {
        let omp = env.root.appendingPathComponent("empty-omp", isDirectory: true)
        try FileManager.default.createDirectory(at: omp, withIntermediateDirectories: true)
        return .init(
            piSessionsRoot: env.piSessionsRoot,
            ompSessionsRoot: omp,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0,
            environment: ["HOME": env.root.path])
    }

    private func scan(
        _ day: Date, now: Date, options: PiSessionCostScanner.Options) throws
        -> PiSessionCostScanner.DailyReportResult
    {
        try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .pi, since: day, until: day, now: now, options: options, checkCancellation: nil)
    }

    private func row(
        _ env: CostUsageTestEnvironment,
        _ day: Date,
        input: Int,
        output: Int = 0,
        model: String = "gpt-5.4") -> [String: Any]
    {
        [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant", "provider": "openai-codex", "model": model,
                "usage": ["input": input, "output": output, "totalTokens": input + output],
            ],
        ]
    }

    private func append(_ contents: String, to url: URL) throws {
        let writer = try FileHandle(forWritingTo: url)
        defer { try? writer.close() }
        try writer.seekToEnd()
        try writer.write(contentsOf: Data(contents.utf8))
    }

    private static func catalog(inputCostPerMillion: Double) throws -> ModelsDevCatalog {
        let json = """
        {"openai":{"id":"openai","models":{"gpt-5.6-sol":{
          "id":"gpt-5.6-sol",
          "cost":{"input":\(inputCostPerMillion),"output":30,"cache_read":0.5,"cache_write":6.25}
        }}}}
        """
        return try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
    }
}

private final class PiCostReadReplacement: @unchecked Sendable {
    private let lock = NSLock()
    private let file: URL
    private let replacement: Data
    private let modifiedAt: Date
    private var armed = false
    private var checks = 0
    private var replaced = false

    init(file: URL, replacement: Data, modifiedAt: Date) {
        self.file = file
        self.replacement = replacement
        self.modifiedAt = modifiedAt
    }

    var didReplace: Bool {
        self.lock.withLock { self.replaced }
    }

    func arm() {
        self.lock.withLock {
            self.armed = true
            self.checks = 0
        }
    }

    func check() throws {
        let shouldReplace = self.lock.withLock {
            guard self.armed, !self.replaced else { return false }
            self.checks += 1
            // JSONL checks once before reading and again after the first chunk is loaded.
            guard self.checks == 2 else { return false }
            self.armed = false
            return true
        }
        guard shouldReplace else { return }
        try self.replacement.write(to: self.file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: self.modifiedAt], ofItemAtPath: self.file.path)
        self.lock.withLock { self.replaced = true }
    }
}
