import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageEmptyFragmentTests {
    @Test(arguments: [0, 52, 599])
    func `bounded progress counts empty fragments before and after their contributor`(_ emptyIndex: Int) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let contributorIndex = emptyIndex == 0 ? 599 : 0
        var emptyURL: URL?
        for index in 0..<600 {
            let session = "progress-\(index == emptyIndex ? contributorIndex : index)"
            let url = try env.seedCodexSessionFile(
                day: day,
                filename: String(format: "progress-%04d.jsonl", index),
                contents: Self.header(session: session, day: day, env: env)
                    + (index == emptyIndex
                        ? Self.emptyEvent(day: day, env: env)
                        : Self.tokenEvent(input: 100, output: 10, day: day, env: env)))
            if index == emptyIndex {
                emptyURL = url
            }
        }
        var options = Self.options(env: env)
        options.maxCodexScanDurationPerRefresh = 60
        for pass in 0..<5 {
            _ = Self.report(env: env, day: day, pass: pass, options: options)
        }

        let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let emptyPath = try #require(emptyURL).path
        let empty = try #require(cache.files[emptyPath])
        #expect(empty.codexRows?.isEmpty == true)
        #expect(empty.codexScanComplete == true)
        #expect(cache.files.count == 600)
        #expect(cache.codexActiveLookbackState == nil)
        #expect(cache.codexScanCompletedFiles == 600)
        #expect(cache.codexScanTotalFiles == 600)
        #expect(cache.codexScanCatchUpPending == false)
        #expect(Self.report(env: env, day: day, pass: 5, options: options).summary?.totalTokens == 599 * 110)
    }

    @Test
    func `empty fragment stays complete after empty appends and later accounts for real usage`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let options = Self.options(env: env)
        _ = try env.seedCodexSessionFile(
            day: day,
            filename: "a-contributor.jsonl",
            contents: Self.header(session: "shared", day: day, env: env)
                + Self.tokenEvent(input: 100, output: 10, day: day, env: env))
        let emptyURL = try env.seedCodexSessionFile(
            day: day,
            filename: "b-empty.jsonl",
            contents: Self.header(session: "shared", day: day, env: env) + Self.emptyEvent(day: day, env: env))
        #expect(Self.report(env: env, day: day, pass: 0, options: options).summary?.totalTokens == 110)
        #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).files[emptyURL.path]?.codexScanComplete == true)

        try Self.append(Self.emptyEvent(day: day, env: env), to: emptyURL)
        #expect(Self.report(env: env, day: day, pass: 1, options: options).summary?.totalTokens == 110)
        #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).files[emptyURL.path]?.codexScanComplete == true)

        try Self.append(Self.bareEvent(input: 17, output: 3, day: day, env: env), to: emptyURL)
        #expect(Self.report(env: env, day: day, pass: 2, options: options).summary?.totalTokens == 130)
        #expect(Self.report(env: env, day: day, pass: 3, options: options).summary?.totalTokens == 130)
    }

    @Test(arguments: [false, true], [false, true])
    func `nonempty duplicates preserve append ordinals and recover after contributor removal`(
        _ remove: Bool,
        _ bare: Bool) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let options = Self.options(env: env)
        let contents = Self.header(session: "shared", day: day, env: env)
            + (bare
                ? Self.bareEvent(input: 100, output: 10, day: day, env: env)
                : Self.tokenEvent(input: 100, output: 10, day: day, env: env))
        let contributor = try env.seedCodexSessionFile(day: day, filename: "a-contributor.jsonl", contents: contents)
        let duplicate = try env.seedCodexSessionFile(day: day, filename: "b-duplicate.jsonl", contents: contents)
        #expect(Self.report(env: env, day: day, pass: 0, options: options).summary?.totalTokens == 110)
        #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).files[duplicate.path] == nil)

        if remove {
            try FileManager.default.removeItem(at: contributor)
        } else {
            try Self.append(
                bare
                    ? Self.bareEvent(input: 100, output: 10, day: day, env: env)
                    : Self.tokenEvent(input: 200, output: 20, day: day, env: env),
                to: duplicate)
        }
        #expect(Self.report(env: env, day: day, pass: 1, options: options).summary?.totalTokens == (remove ? 110 : 220))
    }

    @Test
    func `out of window bare usage reparses from the start when an empty fragment grows`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let oldDay = try env.makeLocalNoon(year: 2024, month: 5, day: 10)
        let options = Self.options(env: env)
        _ = try env.seedCodexSessionFile(
            day: day,
            filename: "a-contributor.jsonl",
            contents: Self.header(session: "shared", day: day, env: env)
                + Self.bareEvent(input: 100, output: 10, day: day, env: env))
        let fragment = try env.seedCodexSessionFile(
            day: day,
            filename: "b-fragment.jsonl",
            contents: Self.header(session: "shared", day: day, env: env)
                + Self.bareEvent(input: 100, output: 10, day: oldDay, env: env))
        #expect(Self.report(env: env, day: day, pass: 0, options: options).summary?.totalTokens == 110)
        #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).files[fragment.path]?.codexScanComplete == true)

        try Self.append(Self.bareEvent(input: 100, output: 10, day: day, env: env), to: fragment)
        #expect(Self.report(env: env, day: day, pass: 1, options: options).summary?.totalTokens == 220)
        let rows = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).files[fragment.path]?.codexRows)
        #expect(rows.map(\.eventIndex) == [1])
    }

    @Test
    func `empty fragment retention rejects partial scans token state and deferred buffers`() {
        let complete = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: 10,
            days: [:],
            parsedBytes: 10,
            codexRows: [],
            codexTokenSnapshots: [],
            codexScanTargetSize: 10,
            codexScanComplete: true)
        #expect(CostUsageScanner.isCompleteEmptyCodexFragment(complete))
        let zero = CostUsageCodexTotals(input: 0, cached: 0, output: 0)
        let totalFields: [WritableKeyPath<CostUsageFileUsage, CostUsageCodexTotals?>] = [
            \.lastTotals, \.lastCountedTotals, \.lastRawTotalsBaseline, \.lastRawTotalsWatermark,
        ]
        for field in totalFields {
            var usage = complete
            usage[keyPath: field] = zero
            #expect(!CostUsageScanner.isCompleteEmptyCodexFragment(usage))
        }
        var partial = complete
        partial.codexScanComplete = false
        #expect(!CostUsageScanner.isCompleteEmptyCodexFragment(partial))
        partial = complete
        partial.parsedBytes = 5
        #expect(!CostUsageScanner.isCompleteEmptyCodexFragment(partial))
        partial = complete
        partial.codexScanTargetSize = 20
        #expect(!CostUsageScanner.isCompleteEmptyCodexFragment(partial))
        for subagent in [false, true] {
            var buffered = complete
            buffered.codexReadRetryBufferPresence = CostUsageCodexRetryBufferPresence(
                subagent: subagent,
                unresolvedFork: !subagent)
            #expect(!CostUsageScanner.isCompleteEmptyCodexFragment(buffered))
        }
    }

    private static func options(env: CostUsageTestEnvironment) -> CostUsageScanner.Options {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0)
        options.refreshMinIntervalSeconds = 0
        options.preferNewestCodexSessionsFirst = false
        return options
    }

    private static func report(
        env: CostUsageTestEnvironment,
        day: Date,
        pass: Int,
        options: CostUsageScanner.Options) -> CostUsageDailyReport
    {
        CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(TimeInterval(pass)),
            options: options)
    }

    private static func header(session: String, day: Date, env: CostUsageTestEnvironment) -> String {
        let iso = env.isoString(for: day)
        return #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"\#(session)"}}"# + "\n"
            + #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"openai/gpt-5.2-codex"}}"# + "\n"
    }

    private static func emptyEvent(day: Date, env: CostUsageTestEnvironment) -> String {
        let iso = env.isoString(for: day)
        return #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"token_count","info":null}}"# + "\n"
    }

    private static func tokenEvent(input: Int, output: Int, day: Date, env: CostUsageTestEnvironment) -> String {
        let iso = env.isoString(for: day)
        return #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"token_count","info":"#
            + #"{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"output_tokens":\#(output)},"#
            + #""model":"openai/gpt-5.2-codex"}}}"# + "\n"
    }

    private static func bareEvent(input: Int, output: Int, day: Date, env: CostUsageTestEnvironment) -> String {
        let iso = env.isoString(for: day)
        return #"{"timestamp":"\#(iso)","usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}"# + "\n"
    }

    private static func append(_ contents: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(contents.utf8))
    }
}
