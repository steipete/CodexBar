import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Testing
@testable import CodexBarCore

/// Decoders are parked in a process-wide store, so these tests must not interleave.
@Suite(.serialized)
struct CodexArchivedRolloutMirrorTests {
    /// `zstd -19` of 40 lines `{"type":"event_msg","payload":{"type":"token_count","n":<i>}}`, with an XXH64 checksum.
    private static let compressedFixture =
        "KLUv/WR/CC0EABIGFRiAqw7YPC5WhqLzCyOCt7uESCmW0MFK2gPAnKgbWyo1ryJubKnUvIq2saVS8yrSxpZKzQvMqe7wwSVkIiHAd0Tp"
            + "XgwRcQblwY0lESR8zbv7Uxz5JyioEYBb/64G4DUbEewQ/P8/ww9IkkgkB5FEkvJEIpFM6gVAAICARWy/BGoAdhUBpr9g"

    @Test
    func `decodes a compressed zstd archive with checksum`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let archive = env.root.appendingPathComponent("fixture.zst")
        let decoded = env.root.appendingPathComponent("fixture.jsonl")
        try #require(Data(base64Encoded: Self.compressedFixture)).write(to: archive)

        try CodexArchivedRolloutMirror.decompressFile(at: archive, to: decoded)

        let expected = (1...40).map { #"{"type":"event_msg","payload":{"type":"token_count","n":\#($0)}}"# }
            .joined(separator: "\n") + "\n"
        #expect(try String(contentsOf: decoded, encoding: .utf8) == expected)
    }

    @Test
    func `decodes multi block frames and rejects truncated archives`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let payload = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let frame = Self.rawZstdFrame(payload)
        let archive = env.root.appendingPathComponent("raw.zst")
        let decoded = env.root.appendingPathComponent("raw.out")
        try frame.write(to: archive)

        try CodexArchivedRolloutMirror.decompressFile(at: archive, to: decoded)
        #expect(try Data(contentsOf: decoded) == payload)

        try frame.prefix(frame.count - 1).write(to: archive)
        #expect(throws: CodexArchivedRolloutMirror.DecodeError.truncated) {
            try CodexArchivedRolloutMirror.decompressFile(at: archive, to: decoded)
        }
    }

    @Test
    func `archived rollouts keep counting after codex removes the plain jsonl`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 30)
        let plain = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-2026-08-30T12-00-00-archived.jsonl",
            contents: Self.rollout(stamp: env.isoString(for: day)))
        let archive = URL(fileURLWithPath: plain.path + ".zst")
        try Self.rawZstdFrame(Data(contentsOf: plain)).write(to: archive)
        try FileManager.default.setAttributes([.modificationDate: day], ofItemAtPath: archive.path)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        func totalTokens() -> Int? {
            CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day, now: day, options: options)
                .summary?.totalTokens
        }
        let mirrorRoot = CodexArchivedRolloutMirror.mirrorRoot(for: env.codexSessionsRoot, cacheRoot: env.cacheRoot)
        let mirrored = try #require(Self.mirroredFile(for: plain, sessionsRoot: env.codexSessionsRoot, in: mirrorRoot))

        // Codex writes the archive before deleting the plain rollout; both existing must not double count.
        #expect(totalTokens() == 330)
        #expect(!FileManager.default.fileExists(atPath: mirrored.path))

        try FileManager.default.removeItem(at: plain)
        #expect(totalTokens() == 330)
        #expect(try String(contentsOf: mirrored, encoding: .utf8) == Self.rollout(stamp: env.isoString(for: day)))
        let mirroredDate = try #require(
            FileManager.default.attributesOfItem(atPath: mirrored.path)[.modificationDate] as? Date)
        #expect(abs(mirroredDate.timeIntervalSince(day)) < 1)
        #expect(CostUsageScanner.codexSessionsRoots(options: options).contains(mirrorRoot))

        try FileManager.default.removeItem(at: archive)
        let afterArchiveRemoved = totalTokens()
        #expect(afterArchiveRemoved == nil || afterArchiveRemoved == 0)
        #expect(!FileManager.default.fileExists(atPath: mirrored.path))
    }

    @Test
    func `rollouts without archives leave the root set unchanged`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let options = CostUsageScanner.Options(codexSessionsRoot: env.codexSessionsRoot, cacheRoot: env.cacheRoot)

        let result = try CodexArchivedRolloutMirror.sync(
            sourceRoots: [env.codexSessionsRoot, env.codexArchivedSessionsRoot],
            cacheRoot: env.cacheRoot,
            modifiedSince: nil)

        #expect(result == .init())
        #expect(CostUsageScanner.codexSessionsRoots(options: options).map(\.standardizedFileURL.path)
            == [env.codexSessionsRoot, env.codexArchivedSessionsRoot].map(\.standardizedFileURL.path))
    }

    @Test
    func `budget decodes archives in resumable slices across refreshes`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 30)
        let payload = Self.patternedPayload(count: 300_000)
        for index in 0..<3 {
            try Self.writeArchive(
                env: env,
                day: day,
                name: "rollout-2026-08-30T12-00-0\(index)-\(Self.uuid(index)).jsonl",
                contents: payload,
                modified: day.addingTimeInterval(Double(index)))
        }

        let mirrorRoot = CodexArchivedRolloutMirror.mirrorRoot(for: env.codexSessionsRoot, cacheRoot: env.cacheRoot)
        func decodedBytesOnDisk() -> Int {
            let names = FileManager.default.enumerator(atPath: mirrorRoot.path)?.allObjects as? [String] ?? []
            return names.filter { $0.hasSuffix(".jsonl") || $0.hasSuffix(".resume") }.reduce(0) { total, name in
                let path = mirrorRoot.appendingPathComponent(name).path
                return total + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0)
            }
        }
        var refreshes = 0
        var result = CodexArchivedRolloutMirror.SyncResult(deferred: 1)
        while result.hasPendingWork, refreshes < 20 {
            let before = decodedBytesOnDisk()
            let budget = CostUsageScanner.CodexScanBudget(maxFileBytes: 0, maxBytesPerRefresh: 100_000)
            result = try CodexArchivedRolloutMirror.materialize(
                CodexArchivedRolloutMirror.prepare(sourceRoots: [env.codexSessionsRoot], cacheRoot: env.cacheRoot),
                modifiedSince: nil,
                budget: budget)
            // No refresh decodes past its byte budget, including the first archive, and the budget is charged for it.
            #expect(decodedBytesOnDisk() - before == 100_000)
            #expect(budget.bytesConsumed == 100_000)
            refreshes += 1
        }

        #expect(refreshes == 9)
        let mirrored = try Self.mirroredFiles(in: mirrorRoot)
        #expect(mirrored.count == 3)
        for url in mirrored {
            #expect(try Data(contentsOf: url) == payload)
        }
        #expect(try !Self.hiddenFiles(in: mirrorRoot).contains { $0.hasSuffix(".resume") })
    }

    @Test
    func `decoding pauses when the refresh deadline passes and resumes`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 30)
        let payload = Self.patternedPayload(count: 2_000_000)
        try Self.writeArchive(
            env: env,
            day: day,
            name: "rollout-2026-08-30T12-00-00-\(Self.uuid(0)).jsonl",
            contents: payload,
            modified: day)
        let archive = try #require(CodexArchivedRolloutMirror.prepare(
            sourceRoots: [env.codexSessionsRoot],
            cacheRoot: env.cacheRoot).roots.first?.archives.first)
        var steps = 0

        let paused = try CodexArchivedRolloutMirror.decode(archive, maxNewBytes: .max, shouldPause: {
            steps += 1
            return steps > 3
        })

        #expect(!paused.isComplete)
        #expect(paused.written > 0 && paused.written < Int64(payload.count))
        let finished = try CodexArchivedRolloutMirror.decode(archive, maxNewBytes: .max)
        #expect(finished.isComplete)
        #expect(paused.written + finished.written == Int64(payload.count))
        #expect(try Data(contentsOf: archive.mirrorURL) == payload)
    }

    @Test
    func `an underestimated content size still decodes in budget sized slices`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 30)
        // Two frames: the header only declares the first, tiny frame's size.
        let head = Self.patternedPayload(count: 1000)
        let tail = Data(Self.patternedPayload(count: 600_000).reversed())
        let name = "rollout-2026-08-30T12-00-00-\(Self.uuid(0)).jsonl"
        let plain = try env.writeCodexSessionFile(day: day, filename: name, contents: "")
        try FileManager.default.removeItem(at: plain)
        let archive = URL(fileURLWithPath: plain.path + ".zst")
        try (Self.rawZstdFrame(head) + Self.rawZstdFrame(tail)).write(to: archive)
        try FileManager.default.setAttributes([.modificationDate: day], ofItemAtPath: archive.path)

        var refreshes = 0
        var result = CodexArchivedRolloutMirror.SyncResult(deferred: 1)
        while result.hasPendingWork, refreshes < 50 {
            result = try CodexArchivedRolloutMirror.materialize(
                CodexArchivedRolloutMirror.prepare(sourceRoots: [env.codexSessionsRoot], cacheRoot: env.cacheRoot),
                modifiedSince: nil,
                budget: CostUsageScanner.CodexScanBudget(maxFileBytes: 0, maxBytesPerRefresh: 100_000))
            refreshes += 1
        }

        #expect(refreshes == 7)
        let mirrorRoot = CodexArchivedRolloutMirror.mirrorRoot(for: env.codexSessionsRoot, cacheRoot: env.cacheRoot)
        #expect(try Self.mirroredFiles(in: mirrorRoot).map { try Data(contentsOf: $0) } == [head + tail])
    }

    @Test
    func `an exhausted estimate under an uncapped timed budget does not overflow`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 30)
        let head = Self.patternedPayload(count: 1000)
        let tail = Self.patternedPayload(count: 300_000)
        let plain = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-2026-08-30T12-00-00-\(Self.uuid(0)).jsonl",
            contents: "")
        try FileManager.default.removeItem(at: plain)
        let archiveURL = URL(fileURLWithPath: plain.path + ".zst")
        try (Self.rawZstdFrame(head) + Self.rawZstdFrame(tail)).write(to: archiveURL)
        try FileManager.default.setAttributes([.modificationDate: day], ofItemAtPath: archiveURL.path)
        func refresh(_ budget: CostUsageScanner.CodexScanBudget) throws -> CodexArchivedRolloutMirror.SyncResult {
            try CodexArchivedRolloutMirror.materialize(
                CodexArchivedRolloutMirror.prepare(sourceRoots: [env.codexSessionsRoot], cacheRoot: env.cacheRoot),
                modifiedSince: nil,
                budget: budget)
        }
        // The first slice uses up the header's 1,000-byte estimate.
        #expect(try refresh(CostUsageScanner.CodexScanBudget(maxFileBytes: 0, maxBytesPerRefresh: 1000)).deferred == 1)
        let uncapped = CostUsageScanner.CodexScanBudget(maxFileBytes: 0, maxBytesPerRefresh: 0, maxDuration: 3600)
        uncapped.consume(workBytes: 1)

        let result = try refresh(uncapped)

        #expect(result.materialized == 1)
        let mirrorRoot = CodexArchivedRolloutMirror.mirrorRoot(for: env.codexSessionsRoot, cacheRoot: env.cacheRoot)
        #expect(try Self.mirroredFiles(in: mirrorRoot).map { try Data(contentsOf: $0) } == [head + tail])
    }

    @Test
    func `a slice locked by another process is deferred`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 30)
        let payload = Self.patternedPayload(count: 300_000)
        try Self.writeArchive(
            env: env,
            day: day,
            name: "rollout-2026-08-30T12-00-00-\(Self.uuid(0)).jsonl",
            contents: payload,
            modified: day)
        let inventory = try CodexArchivedRolloutMirror.prepare(
            sourceRoots: [env.codexSessionsRoot],
            cacheRoot: env.cacheRoot)
        let archive = try #require(inventory.roots.first?.archives.first)
        try FileManager.default.createDirectory(
            at: archive.resumeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let holder = open(archive.resumeURL.path, O_RDWR | O_CREAT, 0o644)
        try #require(holder >= 0)
        try #require(flock(holder, LOCK_EX | LOCK_NB) == 0)

        let blocked = try CodexArchivedRolloutMirror.materialize(inventory, modifiedSince: nil)

        #expect(blocked.deferred == 1)
        #expect(blocked.materialized == 0)
        #expect(!FileManager.default.fileExists(atPath: archive.mirrorURL.path))
        flock(holder, LOCK_UN)
        close(holder)
        let unblocked = try CodexArchivedRolloutMirror.materialize(inventory, modifiedSince: nil)
        #expect(unblocked.materialized == 1)
        #expect(try Data(contentsOf: archive.mirrorURL) == payload)
    }

    @Test
    func `parked decoders are capped`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        CodexArchivedRolloutMirror.discardDecodeSessionsForTesting()
        defer { CodexArchivedRolloutMirror.discardDecodeSessionsForTesting() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 30)
        for index in 0..<4 {
            try Self.writeArchive(
                env: env,
                day: day,
                name: "rollout-2026-08-30T12-00-0\(index)-\(Self.uuid(index)).jsonl",
                contents: Self.patternedPayload(count: 400_000),
                modified: day.addingTimeInterval(Double(index)))
        }
        let archives = try CodexArchivedRolloutMirror.prepare(
            sourceRoots: [env.codexSessionsRoot],
            cacheRoot: env.cacheRoot).roots.flatMap(\.archives)

        for archive in archives {
            #expect(try !CodexArchivedRolloutMirror.decode(archive, maxNewBytes: 50000).isComplete)
        }

        #expect(CodexArchivedRolloutMirror.parkedDecodeSessionCountForTesting == 2)
    }

    @Test(arguments: [false, true])
    func `the scanner counts a large archive once after slicing it across refreshes`(plainControl: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 30)
        let stamp = env.isoString(for: day)
        let events = 3000
        var lines = [
            #"{"type":"session_meta","payload":{"id":"\#(Self.uuid(0))","source":"vscode","timestamp":"\#(stamp)"}}"#,
            #"{"type":"turn_context","timestamp":"\#(stamp)","payload":{"model":"gpt-5.4"}}"#,
        ]
        for index in 1...events {
            lines.append(#"{"type":"event_msg","timestamp":"\#(stamp)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":\#(index * 10),"output_tokens":0}}}}"#)
        }
        let rollout = Data((lines.joined(separator: "\n") + "\n").utf8)
        #expect(rollout.count > 400_000)
        if plainControl {
            _ = try env.writeCodexSessionFile(
                day: day,
                filename: "rollout-2026-08-30T12-00-00-\(Self.uuid(0)).jsonl",
                contents: #require(String(bytes: rollout, encoding: .utf8)))
        } else {
            try Self.writeArchive(
                env: env,
                day: day,
                name: "rollout-2026-08-30T12-00-00-\(Self.uuid(0)).jsonl",
                contents: rollout,
                modified: day)
        }
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        options.maxCodexSessionFileBytes = 150_000
        options.maxCodexScanBytesPerRefresh = 150_000

        var totals: [Int?] = []
        var pending = true
        while pending, totals.count < 20 {
            // Each refresh happens later, like the app's catch-up passes; a frozen clock never resumes.
            let now = day.addingTimeInterval(Double(totals.count + 1))
            totals.append(CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: now,
                options: options).summary?.totalTokens)
            pending = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexScanCatchUpPending == true
        }

        #expect(totals.count > 3)
        #expect(totals.last == events * 10)
    }

    @Test(arguments: [false, true])
    func `paused slices resume from disk with or without the in memory decoder`(relaunch: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 30)
        let payload = Self.patternedPayload(count: 700_000)
        try Self.writeArchive(
            env: env,
            day: day,
            name: "rollout-2026-08-30T12-00-00-\(Self.uuid(0)).jsonl",
            contents: payload,
            modified: day)
        func refresh(_ limit: Int64) throws -> CodexArchivedRolloutMirror.SyncResult {
            try CodexArchivedRolloutMirror.materialize(
                CodexArchivedRolloutMirror.prepare(sourceRoots: [env.codexSessionsRoot], cacheRoot: env.cacheRoot),
                modifiedSince: nil,
                budget: CostUsageScanner.CodexScanBudget(maxFileBytes: 0, maxBytesPerRefresh: limit))
        }

        #expect(try refresh(250_000).deferred == 1)
        if relaunch { CodexArchivedRolloutMirror.discardDecodeSessionsForTesting() }
        #expect(try refresh(250_000).deferred == 1)
        if relaunch { CodexArchivedRolloutMirror.discardDecodeSessionsForTesting() }
        #expect(try refresh(250_000).materialized == 1)

        let mirrorRoot = CodexArchivedRolloutMirror.mirrorRoot(for: env.codexSessionsRoot, cacheRoot: env.cacheRoot)
        #expect(try Self.mirroredFiles(in: mirrorRoot).map { try Data(contentsOf: $0) } == [payload])
    }

    @Test
    func `a changed archive restarts its slice`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 30)
        let name = "rollout-2026-08-30T12-00-00-\(Self.uuid(0)).jsonl"
        try Self.writeArchive(
            env: env,
            day: day,
            name: name,
            contents: Self.patternedPayload(count: 500_000),
            modified: day)
        _ = try CodexArchivedRolloutMirror.materialize(
            CodexArchivedRolloutMirror.prepare(sourceRoots: [env.codexSessionsRoot], cacheRoot: env.cacheRoot),
            modifiedSince: nil,
            budget: CostUsageScanner.CodexScanBudget(maxFileBytes: 0, maxBytesPerRefresh: 200_000))
        let replacement = Data(Self.patternedPayload(count: 400_000).reversed())
        try Self.writeArchive(
            env: env,
            day: day,
            name: name,
            contents: replacement,
            modified: day.addingTimeInterval(60))

        let result = try CodexArchivedRolloutMirror.materialize(
            CodexArchivedRolloutMirror.prepare(sourceRoots: [env.codexSessionsRoot], cacheRoot: env.cacheRoot),
            modifiedSince: nil)

        #expect(result.materialized == 1)
        let mirrorRoot = CodexArchivedRolloutMirror.mirrorRoot(for: env.codexSessionsRoot, cacheRoot: env.cacheRoot)
        #expect(try Self.mirroredFiles(in: mirrorRoot).map { try Data(contentsOf: $0) } == [replacement])
        #expect(try !Self.hiddenFiles(in: mirrorRoot).contains { $0.hasSuffix(".resume") })
    }

    @Test
    func `a slice longer than its archive restarts in the same refresh`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 30)
        let payload = Self.patternedPayload(count: 200_000)
        try Self.writeArchive(
            env: env,
            day: day,
            name: "rollout-2026-08-30T12-00-00-\(Self.uuid(0)).jsonl",
            contents: payload,
            modified: day)
        let inventory = try CodexArchivedRolloutMirror.prepare(
            sourceRoots: [env.codexSessionsRoot],
            cacheRoot: env.cacheRoot)
        let archive = try #require(inventory.roots.first?.archives.first)
        try FileManager.default.createDirectory(
            at: archive.resumeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(repeating: 0x7A, count: 250_000).write(to: archive.resumeURL)

        let result = try CodexArchivedRolloutMirror.materialize(inventory, modifiedSince: nil)

        #expect(result.materialized == 1)
        #expect(try Data(contentsOf: archive.mirrorURL) == payload)
    }

    @Test
    func `an unavailable slice is retried next refresh without recording a failure`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 30)
        let payload = Self.patternedPayload(count: 100_000)
        try Self.writeArchive(
            env: env,
            day: day,
            name: "rollout-2026-08-30T12-00-00-\(Self.uuid(0)).jsonl",
            contents: payload,
            modified: day)
        let inventory = try CodexArchivedRolloutMirror.prepare(
            sourceRoots: [env.codexSessionsRoot],
            cacheRoot: env.cacheRoot)
        let archive = try #require(inventory.roots.first?.archives.first)
        // A directory in the slice's place makes open(2) fail, like a transient volume error.
        try FileManager.default.createDirectory(at: archive.resumeURL, withIntermediateDirectories: true)

        let blocked = try CodexArchivedRolloutMirror.materialize(inventory, modifiedSince: nil)

        #expect(blocked.deferred == 1)
        #expect(blocked.failed == 0)
        let mirrorRoot = try #require(inventory.roots.first?.mirrorRoot)
        #expect(try !Self.hiddenFiles(in: mirrorRoot).contains(".failed-archives.json"))
        try FileManager.default.removeItem(at: archive.resumeURL)
        #expect(try CodexArchivedRolloutMirror.materialize(inventory, modifiedSince: nil).materialized == 1)
        #expect(try Data(contentsOf: archive.mirrorURL) == payload)
    }

    @Test
    func `a small archive near the end of the budget is not counted as partial`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 30)
        try Self.writeArchive(
            env: env,
            day: day,
            name: "rollout-2026-08-30T12-00-00-\(Self.uuid(0)).jsonl",
            contents: Self.patternedPayload(count: 5000),
            modified: day)
        let budget = CostUsageScanner.CodexScanBudget(maxFileBytes: 0, maxBytesPerRefresh: 100_000)
        budget.consume(workBytes: 90000)

        let result = try CodexArchivedRolloutMirror.materialize(
            CodexArchivedRolloutMirror.prepare(sourceRoots: [env.codexSessionsRoot], cacheRoot: env.cacheRoot),
            modifiedSince: nil,
            budget: budget)

        #expect(result.materialized == 1)
        #expect(budget.resumedPartialFileCount == 0)
        #expect(budget.bytesConsumed == 95000)
    }

    @Test
    func `cancellation keeps the slice and a later refresh finishes it`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 30)
        let payload = Self.patternedPayload(count: 600_000)
        try Self.writeArchive(
            env: env,
            day: day,
            name: "rollout-2026-08-30T12-00-00-\(Self.uuid(0)).jsonl",
            contents: payload,
            modified: day)
        let inventory = try CodexArchivedRolloutMirror.prepare(
            sourceRoots: [env.codexSessionsRoot],
            cacheRoot: env.cacheRoot)
        var checks = 0
        let cancelMidArchive: CostUsageScanner.CancellationCheck = {
            checks += 1
            // The first checks run before decoding; later ones run between input chunks.
            if checks > 3 { throw CancellationError() }
        }

        #expect(throws: CancellationError.self) {
            try CodexArchivedRolloutMirror.materialize(
                inventory,
                modifiedSince: nil,
                checkCancellation: cancelMidArchive)
        }

        let mirrorRoot = try #require(inventory.roots.first?.mirrorRoot)
        #expect(try !Self.hiddenFiles(in: mirrorRoot).contains(".failed-archives.json"))
        #expect(try Self.mirroredFiles(in: mirrorRoot).isEmpty)
        let finished = try CodexArchivedRolloutMirror.materialize(
            CodexArchivedRolloutMirror.prepare(sourceRoots: [env.codexSessionsRoot], cacheRoot: env.cacheRoot),
            modifiedSince: nil)
        #expect(finished.materialized == 1)
        #expect(try Self.mirroredFiles(in: mirrorRoot).map { try Data(contentsOf: $0) } == [payload])
    }

    @Test
    func `failed archives keep catch up pending until they decode`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 30)
        let stamp = env.isoString(for: day)
        try Self.writeArchive(
            env: env,
            day: day,
            name: "rollout-2026-08-30T12-00-00-\(Self.uuid(0)).jsonl",
            contents: Data(Self.rollout(stamp: stamp).utf8),
            modified: day)
        let brokenName = "rollout-2026-08-30T12-00-01-\(Self.uuid(1)).jsonl"
        let broken = Data(Self.rollout(stamp: stamp).utf8)
        try Self.writeArchive(env: env, day: day, name: brokenName, contents: broken, modified: day, truncate: true)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        func totalTokens() -> Int? {
            CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day, now: day, options: options)
                .summary?.totalTokens
        }

        #expect(totalTokens() == 330)
        #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexScanCatchUpPending == true)

        // A repaired archive (new size and mtime) is retried without waiting out the interval.
        try Self.writeArchive(
            env: env,
            day: day,
            name: brokenName,
            contents: broken,
            modified: day.addingTimeInterval(60))
        #expect(totalTokens() == 660)
        #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexScanCatchUpPending == false)
    }

    @Test
    func `failed archives back off until the retry interval passes`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 30)
        try Self.writeArchive(
            env: env,
            day: day,
            name: "rollout-2026-08-30T12-00-00-\(Self.uuid(0)).jsonl",
            contents: Data(repeating: 0x63, count: 1000),
            modified: day,
            truncate: true)
        let now = Date()
        func attempt(at date: Date) throws -> CodexArchivedRolloutMirror.SyncResult {
            try CodexArchivedRolloutMirror.materialize(
                CodexArchivedRolloutMirror.prepare(sourceRoots: [env.codexSessionsRoot], cacheRoot: env.cacheRoot),
                modifiedSince: nil,
                now: date)
        }
        let mirrorRoot = CodexArchivedRolloutMirror.mirrorRoot(for: env.codexSessionsRoot, cacheRoot: env.cacheRoot)
        let ledgerURL = mirrorRoot.appendingPathComponent(".failed-archives.json")
        func attemptedAt() throws -> Date? {
            try JSONDecoder().decode(
                [String: CodexArchivedRolloutMirror.FailedArchive].self,
                from: Data(contentsOf: ledgerURL)).values.first?.attemptedAt
        }

        #expect(try attempt(at: now).failed == 1)
        let firstAttempt = try attemptedAt()
        #expect(try attempt(at: now.addingTimeInterval(60)).failed == 1)
        #expect(try attemptedAt() == firstAttempt)
        let retryAt = now.addingTimeInterval(CodexArchivedRolloutMirror.failedArchiveRetryInterval + 1)
        #expect(try attempt(at: retryAt).failed == 1)
        #expect(try attemptedAt() != firstAttempt)
    }

    @Test
    func `a replay paused by the deadline continues after a relaunch`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 30)
        let payload = Self.patternedPayload(count: 1_000_000)
        try Self.writeArchive(
            env: env,
            day: day,
            name: "rollout-2026-08-30T12-00-00-\(Self.uuid(0)).jsonl",
            contents: payload,
            modified: day)
        let archive = try #require(CodexArchivedRolloutMirror.prepare(
            sourceRoots: [env.codexSessionsRoot],
            cacheRoot: env.cacheRoot).roots.first?.archives.first)
        #expect(try !CodexArchivedRolloutMirror.decode(archive, maxNewBytes: 900_000).isComplete)
        CodexArchivedRolloutMirror.discardDecodeSessionsForTesting()

        // Each refresh replays only part of the 900,000 bytes already on disk before its deadline.
        var refreshes = 0
        var complete = false
        while !complete, refreshes < 10 {
            refreshes += 1
            var checks = 0
            complete = try CodexArchivedRolloutMirror.decode(archive, maxNewBytes: .max, shouldPause: {
                checks += 1
                return checks > 2
            }).isComplete
        }

        #expect(complete)
        #expect(refreshes > 1)
        #expect(try Data(contentsOf: archive.mirrorURL) == payload)
    }

    @Test
    func `an admitted archive decodes a step even when its deadline has passed`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 30)
        let payload = Self.patternedPayload(count: 600_000)
        try Self.writeArchive(
            env: env,
            day: day,
            name: "rollout-2026-08-30T12-00-00-\(Self.uuid(0)).jsonl",
            contents: payload,
            modified: day)
        let archive = try #require(CodexArchivedRolloutMirror.prepare(
            sourceRoots: [env.codexSessionsRoot],
            cacheRoot: env.cacheRoot).roots.first?.archives.first)

        // The deadline lapsed between admission and decoding on every refresh.
        var refreshes = 0
        var complete = false
        while !complete, refreshes < 20 {
            refreshes += 1
            complete = try CodexArchivedRolloutMirror.decode(archive, maxNewBytes: .max, shouldPause: { true })
                .isComplete
        }

        #expect(complete)
        #expect(refreshes > 1)
        #expect(try Data(contentsOf: archive.mirrorURL) == payload)
    }

    @Test
    func `archives keep decoding when listing them uses up every refresh deadline`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 30)
        let payloads = [Self.patternedPayload(count: 600_000), Self.patternedPayload(count: 400_000)]
        for (index, payload) in payloads.enumerated() {
            try Self.writeArchive(
                env: env,
                day: day,
                name: "rollout-2026-08-30T12-00-0\(index)-\(Self.uuid(index)).jsonl",
                contents: payload,
                modified: day.addingTimeInterval(TimeInterval(index)))
        }

        var refreshes = 0
        var result = CodexArchivedRolloutMirror.SyncResult(deferred: 1)
        while result.hasPendingWork, refreshes < 40 {
            refreshes += 1
            // The deadline has passed by the time the archives are listed, on every refresh.
            let budget = CostUsageScanner.CodexScanBudget(maxFileBytes: 0, maxBytesPerRefresh: 0, maxDuration: 1e-6)
            let inventory = try CodexArchivedRolloutMirror.prepare(
                sourceRoots: [env.codexSessionsRoot],
                cacheRoot: env.cacheRoot)
            result = try CodexArchivedRolloutMirror.materialize(inventory, modifiedSince: nil, budget: budget)
        }

        #expect(!result.hasPendingWork)
        #expect(refreshes > 2)
        let mirrorRoot = CodexArchivedRolloutMirror.mirrorRoot(for: env.codexSessionsRoot, cacheRoot: env.cacheRoot)
        #expect(try Set(Self.mirroredFiles(in: mirrorRoot).map { try Data(contentsOf: $0) }) == Set(payloads))
    }

    @Test
    func `cancellation interrupts the archive walks`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 30)
        for index in 0..<300 {
            _ = try env.writeCodexSessionFile(
                day: day,
                filename: "rollout-2026-08-30T12-00-00-\(Self.uuid(index)).jsonl",
                contents: "")
        }
        let cancel: CostUsageScanner.CancellationCheck = { throw CancellationError() }

        #expect(throws: CancellationError.self) {
            try CodexArchivedRolloutMirror.ensureMirrorRoots(
                sourceRoots: [env.codexSessionsRoot],
                cacheRoot: env.cacheRoot,
                checkCancellation: cancel)
        }
        // `prepare` already checks once per root; cancel only once the walk itself is running.
        var checks = 0
        #expect(throws: CancellationError.self) {
            try CodexArchivedRolloutMirror.prepare(
                sourceRoots: [env.codexSessionsRoot],
                cacheRoot: env.cacheRoot,
                checkCancellation: {
                    checks += 1
                    if checks > 1 { throw CancellationError() }
                })
        }
    }

    // MARK: - Fixtures

    static func rollout(stamp: String) -> String {
        [
            #"{"type":"turn_context","timestamp":"\#(stamp)","payload":{"model":"gpt-5.4"}}"#,
            #"{"type":"event_msg","timestamp":"\#(stamp)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":100,"output_tokens":10}}}}"#,
            #"{"type":"event_msg","timestamp":"\#(stamp)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":300,"output_tokens":30}}}}"#,
        ].joined(separator: "\n") + "\n"
    }

    private static func mirroredFile(for plain: URL, sessionsRoot: URL, in mirrorRoot: URL) -> URL? {
        let rootPath = sessionsRoot.standardizedFileURL.path + "/"
        let path = plain.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return nil }
        return mirrorRoot.appendingPathComponent(String(path.dropFirst(rootPath.count)), isDirectory: false)
    }

    /// Non-repeating bytes, so a misplaced resume offset changes the decoded content.
    static func patternedPayload(count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 9)) })
    }

    private static func mirroredFiles(in mirrorRoot: URL) throws -> [URL] {
        let names = FileManager.default.enumerator(atPath: mirrorRoot.path)?.allObjects as? [String] ?? []
        return names.filter { ($0 as NSString).lastPathComponent.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }
            .map { mirrorRoot.appendingPathComponent($0) }
    }

    private static func hiddenFiles(in mirrorRoot: URL) throws -> [String] {
        let names = FileManager.default.enumerator(atPath: mirrorRoot.path)?.allObjects as? [String] ?? []
        return names.map { ($0 as NSString).lastPathComponent }.filter { $0.hasPrefix(".") }
    }

    static func uuid(_ index: Int) -> String {
        String(format: "0199f0a0-0000-7000-8000-%012d", index)
    }

    /// Writes `name.zst` (a raw-block zstd frame of `contents`) into the day's sessions folder.
    static func writeArchive(
        env: CostUsageTestEnvironment,
        day: Date,
        name: String,
        contents: Data,
        modified: Date,
        truncate: Bool = false) throws
    {
        let plain = try env.writeCodexSessionFile(day: day, filename: name, contents: "")
        try FileManager.default.removeItem(at: plain)
        let archive = URL(fileURLWithPath: plain.path + ".zst")
        let frame = Self.rawZstdFrame(contents)
        try (truncate ? frame.prefix(frame.count - 1) : frame).write(to: archive)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: archive.path)
    }

    /// A single-segment zstd frame of raw (stored) blocks, so tests can build archives without a compressor.
    private static func rawZstdFrame(_ payload: Data) -> Data {
        var frame = Data([0x28, 0xB5, 0x2F, 0xFD, 0xE0])
        withUnsafeBytes(of: UInt64(payload.count).littleEndian) { frame.append(contentsOf: $0) }
        let maxBlock = 128 * 1024
        var offset = 0
        repeat {
            let size = min(maxBlock, payload.count - offset)
            let isLast = offset + size == payload.count
            let header = UInt32(size) << 3 | (isLast ? 1 : 0)
            frame.append(contentsOf: [UInt8(header & 0xFF), UInt8(header >> 8 & 0xFF), UInt8(header >> 16 & 0xFF)])
            frame.append(payload.subdata(in: offset..<offset + size))
            offset += size
        } while offset < payload.count
        return frame
    }
}
