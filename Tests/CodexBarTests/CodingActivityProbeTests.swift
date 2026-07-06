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

    /// Writes an empty file at `path` (relative to `home`) and sets its modification date, creating
    /// intermediate directories as needed. Only mtime matters to the probe — contents are never read.
    @discardableResult
    private func writeTranscript(
        at path: String,
        under home: URL,
        modified: Date,
        fileManager: FileManager) throws -> URL
    {
        let url = home.appendingPathComponent(path, isDirectory: false)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(fileManager.createFile(atPath: url.path, contents: nil))
        try fileManager.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
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
}
