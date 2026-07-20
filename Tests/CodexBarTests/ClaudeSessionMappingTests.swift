import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeSessionMappingTests {
    @Test
    func `cwd escaping replaces every non alphanumeric ASCII byte`() {
        #expect(ClaudeSessionProjectMapper.escapedCWD("/Users/test/My Project_v2") == "-Users-test-My-Project-v2")
    }

    @Test
    func `newest transcript is selected from mapped project directory`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSessionMappingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let cwd = "/Users/test/Projects/alpha"
        let projectDirectory = home
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(ClaudeSessionProjectMapper.escapedCWD(cwd), isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let older = projectDirectory.appendingPathComponent("older.jsonl")
        let newer = projectDirectory.appendingPathComponent("newer.jsonl")
        try Data("fixture\n".utf8).write(to: older)
        try Data("fixture\n".utf8).write(to: newer)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: older.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: newer.path)

        let match = try #require(ClaudeSessionProjectMapper.newestTranscript(cwd: cwd, homeDirectory: home))
        #expect(match.url.lastPathComponent == "newer.jsonl")
        #expect(match.modifiedAt == Date(timeIntervalSince1970: 200))

        let bounded = ClaudeSessionProjectMapper.transcripts(
            cwd: cwd,
            homeDirectory: home,
            limit: 1,
            now: Date(timeIntervalSince1970: 150))
        #expect(bounded.map(\.url.lastPathComponent) == ["newer.jsonl"])
        #expect(bounded.first?.modifiedAt == Date(timeIntervalSince1970: 150))
    }

    @Test
    func `directory metadata scan bounds entry count depth and time`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSessionMappingBoundsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["one.jsonl", "two.jsonl", "three.jsonl"] {
            try Data("fixture\n".utf8).write(to: root.appendingPathComponent(name))
        }
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("fixture\n".utf8).write(to: nested.appendingPathComponent("nested.jsonl"))

        var bounded = DirectoryMetadataScanBudget(maxEntryCount: 2, maxDepth: 1, timeLimit: 60)
        let files = bounded.files(in: root)
        #expect(files.count <= 2)
        #expect(!files.contains { $0.deletingLastPathComponent() == nested })

        var expired = DirectoryMetadataScanBudget(maxEntryCount: 100, maxDepth: 2, timeLimit: 0)
        #expect(expired.files(in: root).isEmpty)
    }

    @Test
    func `future modification dates use one path free clamp anchor`() {
        let url = URL(fileURLWithPath: "/tmp/future-session.jsonl")
        let firstNow = Date(timeIntervalSinceReferenceDate: 100)
        let clamp = FutureModificationDateClamp(clampDate: firstNow)
        let future = firstNow.addingTimeInterval(3600)

        #expect(clamp.clamp(url: url, modifiedAt: future, now: firstNow) == firstNow)
        #expect(clamp.clamp(
            url: url,
            modifiedAt: future,
            now: firstNow.addingTimeInterval(30)) == firstNow)
        #expect(clamp.clamp(
            url: url,
            modifiedAt: future.addingTimeInterval(1),
            now: firstNow.addingTimeInterval(30)) == firstNow)
    }
}
