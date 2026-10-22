import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Testing
@testable import CodexBarCore

extension CodexArchivedRolloutMirrorTests {
    @Test
    func `decoded transcripts and their folders are private to the owner`() throws {
        let previousMask = umask(0o022)
        defer { umask(previousMask) }
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 30)
        let payload = Self.patternedPayload(count: 500_000)
        try Self.writeArchive(
            env: env,
            day: day,
            name: "rollout-2026-08-30T12-00-00-\(Self.uuid(0)).jsonl",
            contents: payload,
            modified: day)
        let archive = try #require(CodexArchivedRolloutMirror.prepare(
            sourceRoots: [env.codexSessionsRoot],
            cacheRoot: env.cacheRoot).roots.first?.archives.first)
        let mirrorRoot = CodexArchivedRolloutMirror.mirrorRoot(for: env.codexSessionsRoot, cacheRoot: env.cacheRoot)

        #expect(try !CodexArchivedRolloutMirror.decode(archive, maxNewBytes: 100_000).isComplete)
        #expect(Self.mode(of: archive.resumeURL) == 0o600)
        #expect(try CodexArchivedRolloutMirror.decode(archive, maxNewBytes: .max).isComplete)
        #expect(Self.mode(of: archive.mirrorURL) == 0o600)
        let dayFolder = archive.mirrorURL.deletingLastPathComponent()
        for directory in [mirrorRoot.deletingLastPathComponent(), mirrorRoot, dayFolder] {
            #expect(Self.mode(of: directory) == 0o700, "\(directory.path)")
        }

        try Self.writeArchive(
            env: env,
            day: day,
            name: "rollout-2026-08-30T13-00-00-\(Self.uuid(1)).jsonl",
            contents: Data(repeating: 0x63, count: 1000),
            modified: day,
            truncate: true)
        let result = try CodexArchivedRolloutMirror.materialize(
            CodexArchivedRolloutMirror.prepare(sourceRoots: [env.codexSessionsRoot], cacheRoot: env.cacheRoot),
            modifiedSince: nil)
        #expect(result.failed == 1)
        #expect(Self.mode(of: mirrorRoot.appendingPathComponent(".failed-archives.json")) == 0o600)
    }

    @Test
    func `mirrors and slices left readable by an earlier build are made private`() throws {
        let previousMask = umask(0o022)
        defer { umask(previousMask) }
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 30)
        try Self.writeArchive(
            env: env,
            day: day,
            name: "rollout-2026-08-30T12-00-00-\(Self.uuid(0)).jsonl",
            contents: Self.patternedPayload(count: 500_000),
            modified: day)
        try Self.writeArchive(
            env: env,
            day: day,
            name: "rollout-2026-08-30T13-00-00-\(Self.uuid(1)).jsonl",
            contents: Self.patternedPayload(count: 1000),
            modified: day)
        let archives = try CodexArchivedRolloutMirror.prepare(
            sourceRoots: [env.codexSessionsRoot],
            cacheRoot: env.cacheRoot).roots.flatMap(\.archives).sorted { $0.relativePath < $1.relativePath }
        let (sliced, published) = (archives[0], archives[1])
        #expect(try !CodexArchivedRolloutMirror.decode(sliced, maxNewBytes: 100_000).isComplete)
        #expect(try CodexArchivedRolloutMirror.decode(published, maxNewBytes: .max).isComplete)
        let mirrorRoot = CodexArchivedRolloutMirror.mirrorRoot(for: env.codexSessionsRoot, cacheRoot: env.cacheRoot)
        let directories = [mirrorRoot.deletingLastPathComponent(), mirrorRoot]
        for file in [sliced.resumeURL, published.mirrorURL] {
            #expect(chmod(file.path, 0o644) == 0)
        }
        for directory in directories {
            #expect(chmod(directory.path, 0o755) == 0)
        }

        _ = try CodexArchivedRolloutMirror.prepare(sourceRoots: [env.codexSessionsRoot], cacheRoot: env.cacheRoot)

        #expect(Self.mode(of: sliced.resumeURL) == 0o600)
        #expect(Self.mode(of: published.mirrorURL) == 0o600)
        for directory in directories {
            #expect(Self.mode(of: directory) == 0o700, "\(directory.path)")
        }
        // A slice loosened after listing is still tightened before decoding resumes into it.
        #expect(chmod(sliced.resumeURL.path, 0o644) == 0)
        #expect(try CodexArchivedRolloutMirror.decode(sliced, maxNewBytes: .max).isComplete)
        #expect(Self.mode(of: sliced.mirrorURL) == 0o600)

        // Replacing a loosened mirror after its archive changes does not inherit the old mode.
        try Self.writeArchive(
            env: env,
            day: day,
            name: "rollout-2026-08-30T13-00-00-\(Self.uuid(1)).jsonl",
            contents: Self.patternedPayload(count: 2000),
            modified: day.addingTimeInterval(60))
        let changed = try #require(CodexArchivedRolloutMirror.prepare(
            sourceRoots: [env.codexSessionsRoot],
            cacheRoot: env.cacheRoot).roots.flatMap(\.archives).first { $0.mirrorURL == published.mirrorURL })
        #expect(chmod(published.mirrorURL.path, 0o644) == 0)
        #expect(try CodexArchivedRolloutMirror.decode(changed, maxNewBytes: .max).isComplete)
        #expect(try Data(contentsOf: published.mirrorURL) == Self.patternedPayload(count: 2000))
        #expect(Self.mode(of: published.mirrorURL) == 0o600)
    }

    private static func mode(of url: URL) -> mode_t? {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return nil }
        return status.st_mode & 0o777
    }
}
