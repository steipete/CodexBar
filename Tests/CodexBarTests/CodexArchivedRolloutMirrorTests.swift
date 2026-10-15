import Foundation
import Testing
@testable import CodexBarCore

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
    func `budget decodes one archive per refresh and defers the rest`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 30)
        let payload = Data(repeating: 0x61, count: 300_000)
        for index in 0..<3 {
            try Self.writeArchive(
                env: env,
                day: day,
                name: "rollout-2026-08-30T12-00-0\(index)-\(Self.uuid(index)).jsonl",
                contents: payload,
                modified: day.addingTimeInterval(Double(index)))
        }
        let inventory = try CodexArchivedRolloutMirror.prepare(
            sourceRoots: [env.codexSessionsRoot],
            cacheRoot: env.cacheRoot)

        let first = try CodexArchivedRolloutMirror.materialize(
            inventory,
            modifiedSince: nil,
            budget: CostUsageScanner.CodexScanBudget(maxFileBytes: 0, maxBytesPerRefresh: 100_000))

        // The first archive exceeds the budget but still decodes, so each refresh makes progress.
        #expect(first.materialized == 1)
        #expect(first.deferred == 2)
        #expect(first.hasPendingWork)
        let second = try CodexArchivedRolloutMirror.materialize(
            CodexArchivedRolloutMirror.prepare(sourceRoots: [env.codexSessionsRoot], cacheRoot: env.cacheRoot),
            modifiedSince: nil,
            budget: CostUsageScanner.CodexScanBudget(maxFileBytes: 0, maxBytesPerRefresh: 0))
        #expect(second.materialized == 2)
        #expect(!second.hasPendingWork)
    }

    @Test
    func `decoding stops at cancellation without recording a failure`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 30)
        try Self.writeArchive(
            env: env,
            day: day,
            name: "rollout-2026-08-30T12-00-00-\(Self.uuid(0)).jsonl",
            contents: Data(repeating: 0x62, count: 600_000),
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
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: mirrorRoot.path)
        #expect(!leftovers.contains(".failed-archives.json"))
        let files = FileManager.default.enumerator(atPath: mirrorRoot.path)?.allObjects as? [String] ?? []
        #expect(!files.contains { $0.hasSuffix(".jsonl") || $0.hasSuffix(".partial") })
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
    func `forks in the window decode their archived parent from before the window`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let parentDay = try env.makeLocalNoon(year: 2026, month: 8, day: 1)
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 17)
        let parentId = Self.uuid(10)
        let childId = Self.uuid(11)
        func metadata(_ id: String, parent: String?, at date: Date) -> String {
            let fork = parent.map { #","forked_from_id":"\#($0)""# } ?? ""
            return #"{"type":"session_meta","payload":{"id":"\#(id)","source":"vscode","#
                + #""thread_source":"user","timestamp":"\#(env.isoString(for: date))"\#(fork)}}"#
        }
        func tokens(_ input: Int, last: Int, at date: Date) -> String {
            #"{"type":"event_msg","timestamp":"\#(env.isoString(for: date))","payload":{"type":"token_count","#
                + #""info":{"model":"gpt-5.4","total_token_usage":{"input_tokens":\#(input),"output_tokens":0},"#
                + #""last_token_usage":{"input_tokens":\#(last),"output_tokens":0}}}}"#
        }
        let parent = [metadata(parentId, parent: nil, at: parentDay), tokens(1000, last: 1000, at: parentDay)]
        try Self.writeArchive(
            env: env,
            day: parentDay,
            name: "rollout-2026-08-01T12-00-00-\(parentId).jsonl",
            contents: Data((parent.joined(separator: "\n") + "\n").utf8),
            modified: parentDay)
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-2026-09-17T12-00-00-\(childId).jsonl",
            contents: [
                metadata(childId, parent: parentId, at: day),
                tokens(1000, last: 1000, at: day.addingTimeInterval(1)),
                tokens(1020, last: 20, at: day.addingTimeInterval(2)),
            ].joined(separator: "\n") + "\n")
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0

        var total: Int?
        for _ in 0..<4 {
            total = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day,
                options: options)
                .summary?.totalTokens
        }

        // Only the child's own 20 tokens fall in the window; the parent's 1000 are inherited, not billed again.
        #expect(total == 20)
        let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let child = try #require(cache.files.values.first { $0.sessionId == childId })
        #expect(!CostUsageScanner.isUnresolvedMissingParentFork(child))
        #expect(cache.codexScanCatchUpPending == false)
    }

    // MARK: - Fixtures

    private static func rollout(stamp: String) -> String {
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

    private static func uuid(_ index: Int) -> String {
        String(format: "0199f0a0-0000-7000-8000-%012d", index)
    }

    /// Writes `name.zst` (a raw-block zstd frame of `contents`) into the day's sessions folder.
    private static func writeArchive(
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
