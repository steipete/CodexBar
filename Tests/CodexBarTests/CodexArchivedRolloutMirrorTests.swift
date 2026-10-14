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
