import Foundation
import Testing
@testable import CodexBar

/// `CodingActivityProbe` is fork-only shadow-mode telemetry (never upstreamed, never fed into
/// `AdaptiveRefreshPolicy`). These tests build a throwaway fake home directory so they never touch
/// the real `~/.codex` or `~/.claude` trees, and control `now`/mtimes explicitly for deterministic
/// seconds-since assertions.
struct CodingActivityProbeTests {
    private func withFakeHome(_ body: (URL, FileManager) throws -> Void) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        try body(root, fileManager)
    }

    /// Writes a file at `path` (relative to `home`) with `sizeBytes` of content and sets its
    /// modification (and optionally creation) date, creating intermediate directories as needed.
    /// Only file *metadata* matters to the probe — contents are never read, so the bytes written
    /// are always zeroes; only their count matters for `transcriptBytes` assertions.
    @discardableResult
    private func writeTranscript(
        at path: String,
        under home: URL,
        modified: Date,
        created: Date? = nil,
        sizeBytes: Int = 0,
        fileManager: FileManager) throws -> URL
    {
        let url = home.appendingPathComponent(path, isDirectory: false)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(fileManager.createFile(atPath: url.path, contents: Data(repeating: 0, count: sizeBytes)))
        var attributes: [FileAttributeKey: Any] = [.modificationDate: modified]
        if let created { attributes[.creationDate] = created }
        try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
        return url
    }

    /// Thin wrapper around `CodingActivityProbe.sample` fixing `now` to `referenceNow`, so call
    /// sites only need to vary the fake `home`/`fileManager`.
    private func sample(fileManager: FileManager, home: URL) -> CodingActivitySample {
        CodingActivityProbe.sample(now: Self.referenceNow, fileManager: fileManager, homeDirectory: home)
    }

    private static let referenceNow = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static func dayPath(for date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d/%02d/%02d",
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1)
    }

    @Test
    func `reports nil for both signals when neither directory exists`() throws {
        try self.withFakeHome { home, fileManager in
            let sample = self.sample(fileManager: fileManager, home: home)
            #expect(sample.codexSecondsSinceActivity == nil)
            #expect(sample.claudeSecondsSinceActivity == nil)
        }
    }

    @Test
    func `reports seconds since the newest codex transcript in today's day directory`() throws {
        try self.withFakeHome { home, fileManager in
            let modified = Self.referenceNow.addingTimeInterval(-120)
            try self.writeTranscript(
                at: ".codex/sessions/\(Self.dayPath(for: Self.referenceNow))/rollout-a.jsonl",
                under: home,
                modified: modified,
                fileManager: fileManager)

            let sample = self.sample(fileManager: fileManager, home: home)
            #expect(sample.codexSecondsSinceActivity == 120)
        }
    }

    @Test
    func `finds yesterday's codex transcript when today has none`() throws {
        try self.withFakeHome { home, fileManager in
            let yesterday = Self.referenceNow.addingTimeInterval(-86400)
            let modified = yesterday.addingTimeInterval(-30)
            try self.writeTranscript(
                at: ".codex/sessions/\(Self.dayPath(for: yesterday))/rollout-b.jsonl",
                under: home,
                modified: modified,
                fileManager: fileManager)

            let sample = self.sample(fileManager: fileManager, home: home)
            #expect(sample.codexSecondsSinceActivity == Self.referenceNow.timeIntervalSince(modified))
        }
    }

    @Test
    func `does not find a codex transcript from three days ago (outside the bounded lookback)`() throws {
        try self.withFakeHome { home, fileManager in
            let threeDaysAgo = Self.referenceNow.addingTimeInterval(-3 * 86400)
            try self.writeTranscript(
                at: ".codex/sessions/\(Self.dayPath(for: threeDaysAgo))/rollout-c.jsonl",
                under: home,
                modified: threeDaysAgo,
                fileManager: fileManager)

            let sample = self.sample(fileManager: fileManager, home: home)
            #expect(sample.codexSecondsSinceActivity == nil)
        }
    }

    @Test
    func `takes the newer of today and yesterday when both have codex transcripts`() throws {
        try self.withFakeHome { home, fileManager in
            let yesterday = Self.referenceNow.addingTimeInterval(-86400)
            try self.writeTranscript(
                at: ".codex/sessions/\(Self.dayPath(for: yesterday))/rollout-old.jsonl",
                under: home,
                modified: yesterday.addingTimeInterval(-3600),
                fileManager: fileManager)
            let newerModified = Self.referenceNow.addingTimeInterval(-60)
            try self.writeTranscript(
                at: ".codex/sessions/\(Self.dayPath(for: Self.referenceNow))/rollout-new.jsonl",
                under: home,
                modified: newerModified,
                fileManager: fileManager)

            let sample = self.sample(fileManager: fileManager, home: home)
            #expect(sample.codexSecondsSinceActivity == 60)
        }
    }

    @Test
    func `clamps a future codex mtime to zero instead of a negative seconds-since`() throws {
        try self.withFakeHome { home, fileManager in
            let future = Self.referenceNow.addingTimeInterval(3600)
            try self.writeTranscript(
                at: ".codex/sessions/\(Self.dayPath(for: Self.referenceNow))/rollout-future.jsonl",
                under: home,
                modified: future,
                fileManager: fileManager)

            let sample = self.sample(fileManager: fileManager, home: home)
            #expect(sample.codexSecondsSinceActivity == 0)
        }
    }

    @Test
    func `reports seconds since the newest claude transcript directly under a project directory`() throws {
        try self.withFakeHome { home, fileManager in
            let modified = Self.referenceNow.addingTimeInterval(-45)
            try self.writeTranscript(
                at: ".claude/projects/-Users-example-project/session-a.jsonl",
                under: home,
                modified: modified,
                fileManager: fileManager)

            let sample = self.sample(fileManager: fileManager, home: home)
            #expect(sample.claudeSecondsSinceActivity == 45)
        }
    }

    /// The bounded claude walk only looks at a project directory's direct children — it must not
    /// descend into a nested subdirectory such as the memory store other CodexBar tooling writes.
    @Test
    func `ignores claude transcripts nested inside a project subdirectory`() throws {
        try self.withFakeHome { home, fileManager in
            try self.writeTranscript(
                at: ".claude/projects/-Users-example-project/memory/nested.jsonl",
                under: home,
                modified: Self.referenceNow.addingTimeInterval(-10),
                fileManager: fileManager)

            let sample = self.sample(fileManager: fileManager, home: home)
            #expect(sample.claudeSecondsSinceActivity == nil)
        }
    }

    @Test
    func `takes the newest claude transcript across multiple project directories`() throws {
        try self.withFakeHome { home, fileManager in
            try self.writeTranscript(
                at: ".claude/projects/project-a/session.jsonl",
                under: home,
                modified: Self.referenceNow.addingTimeInterval(-500),
                fileManager: fileManager)
            try self.writeTranscript(
                at: ".claude/projects/project-b/session.jsonl",
                under: home,
                modified: Self.referenceNow.addingTimeInterval(-20),
                fileManager: fileManager)

            let sample = self.sample(fileManager: fileManager, home: home)
            #expect(sample.claudeSecondsSinceActivity == 20)
        }
    }

    @Test
    func `ignores non jsonl files alongside transcripts`() throws {
        try self.withFakeHome { home, fileManager in
            try self.writeTranscript(
                at: ".claude/projects/project-a/notes.txt",
                under: home,
                modified: Self.referenceNow.addingTimeInterval(-5),
                fileManager: fileManager)

            let sample = self.sample(fileManager: fileManager, home: home)
            #expect(sample.claudeSecondsSinceActivity == nil)
        }
    }

    @Test
    func `samples codex and claude independently in the same call`() throws {
        try self.withFakeHome { home, fileManager in
            try self.writeTranscript(
                at: ".codex/sessions/\(Self.dayPath(for: Self.referenceNow))/rollout.jsonl",
                under: home,
                modified: Self.referenceNow.addingTimeInterval(-90),
                fileManager: fileManager)
            try self.writeTranscript(
                at: ".claude/projects/project-a/session.jsonl",
                under: home,
                modified: Self.referenceNow.addingTimeInterval(-15),
                fileManager: fileManager)

            let sample = self.sample(fileManager: fileManager, home: home)
            #expect(sample.codexSecondsSinceActivity == 90)
            #expect(sample.claudeSecondsSinceActivity == 15)
        }
    }

    // MARK: - B layer: session duration, transcript bytes, active-transcript count

    @Test
    func `reports session duration as mtime minus creationDate for the newest codex transcript`() throws {
        try self.withFakeHome { home, fileManager in
            try self.writeTranscript(
                at: ".codex/sessions/\(Self.dayPath(for: Self.referenceNow))/rollout.jsonl",
                under: home,
                modified: Self.referenceNow.addingTimeInterval(-60),
                created: Self.referenceNow.addingTimeInterval(-660),
                fileManager: fileManager)

            let sample = self.sample(fileManager: fileManager, home: home)
            #expect(sample.codexSessionDurationSeconds == 600)
        }
    }

    /// A creationDate after mtime (e.g. a file copied/restored with its birthtime reset forward)
    /// must clamp session duration to zero rather than reporting a negative duration.
    @Test
    func `clamps session duration to zero when creationDate is after modificationDate`() throws {
        try self.withFakeHome { home, fileManager in
            try self.writeTranscript(
                at: ".claude/projects/project-a/session.jsonl",
                under: home,
                modified: Self.referenceNow.addingTimeInterval(-100),
                created: Self.referenceNow.addingTimeInterval(-50),
                fileManager: fileManager)

            let sample = self.sample(fileManager: fileManager, home: home)
            #expect(sample.claudeSessionDurationSeconds == 0)
        }
    }

    @Test
    func `reports the newest codex transcript's byte size`() throws {
        try self.withFakeHome { home, fileManager in
            try self.writeTranscript(
                at: ".codex/sessions/\(Self.dayPath(for: Self.referenceNow))/rollout.jsonl",
                under: home,
                modified: Self.referenceNow.addingTimeInterval(-30),
                sizeBytes: 4096,
                fileManager: fileManager)

            let sample = self.sample(fileManager: fileManager, home: home)
            #expect(sample.codexTranscriptBytes == 4096)
        }
    }

    /// The active-transcript count boundary at the 300-second window: a file modified 299s ago
    /// counts as active, one modified 301s ago does not.
    @Test
    func `counts only transcripts modified within the last 300 seconds as active`() throws {
        try self.withFakeHome { home, fileManager in
            try self.writeTranscript(
                at: ".claude/projects/project-a/inside.jsonl",
                under: home,
                modified: Self.referenceNow.addingTimeInterval(-299),
                fileManager: fileManager)
            try self.writeTranscript(
                at: ".claude/projects/project-b/outside.jsonl",
                under: home,
                modified: Self.referenceNow.addingTimeInterval(-301),
                fileManager: fileManager)

            let sample = self.sample(fileManager: fileManager, home: home)
            #expect(sample.claudeActiveTranscriptCount == 1)
        }
    }

    @Test
    func `counts multiple concurrently active codex transcripts`() throws {
        try self.withFakeHome { home, fileManager in
            let today = Self.dayPath(for: Self.referenceNow)
            try self.writeTranscript(
                at: ".codex/sessions/\(today)/rollout-a.jsonl",
                under: home,
                modified: Self.referenceNow.addingTimeInterval(-10),
                fileManager: fileManager)
            try self.writeTranscript(
                at: ".codex/sessions/\(today)/rollout-b.jsonl",
                under: home,
                modified: Self.referenceNow.addingTimeInterval(-20),
                fileManager: fileManager)
            try self.writeTranscript(
                at: ".codex/sessions/\(today)/rollout-c.jsonl",
                under: home,
                modified: Self.referenceNow.addingTimeInterval(-3600),
                fileManager: fileManager)

            let sample = self.sample(fileManager: fileManager, home: home)
            #expect(sample.codexActiveTranscriptCount == 2)
        }
    }

    /// All per-file B-layer fields (session duration, byte size) must describe the same file as
    /// the A-layer seconds-since-activity — i.e. the newest one — even when an older transcript
    /// has a larger size or longer duration that would win if the fields were sourced independently.
    @Test
    func `all per-file fields describe the newest transcript when several exist`() throws {
        try self.withFakeHome { home, fileManager in
            try self.writeTranscript(
                at: ".claude/projects/project-a/older.jsonl",
                under: home,
                modified: Self.referenceNow.addingTimeInterval(-500),
                created: Self.referenceNow.addingTimeInterval(-50000),
                sizeBytes: 99999,
                fileManager: fileManager)
            try self.writeTranscript(
                at: ".claude/projects/project-b/newer.jsonl",
                under: home,
                modified: Self.referenceNow.addingTimeInterval(-10),
                created: Self.referenceNow.addingTimeInterval(-310),
                sizeBytes: 256,
                fileManager: fileManager)

            let sample = self.sample(fileManager: fileManager, home: home)
            #expect(sample.claudeSecondsSinceActivity == 10)
            #expect(sample.claudeSessionDurationSeconds == 300)
            #expect(sample.claudeTranscriptBytes == 256)
        }
    }

    @Test
    func `reports nil for all B-layer fields when no transcript is found`() throws {
        try self.withFakeHome { home, fileManager in
            let sample = self.sample(fileManager: fileManager, home: home)
            #expect(sample.codexSessionDurationSeconds == nil)
            #expect(sample.claudeSessionDurationSeconds == nil)
            #expect(sample.codexTranscriptBytes == nil)
            #expect(sample.claudeTranscriptBytes == nil)
            #expect(sample.codexActiveTranscriptCount == nil)
            #expect(sample.claudeActiveTranscriptCount == nil)
        }
    }
}
