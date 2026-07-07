import CodexBarCore
import Foundation
import Testing

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
    }
}
