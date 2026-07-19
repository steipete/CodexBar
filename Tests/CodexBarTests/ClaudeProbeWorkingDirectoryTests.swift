import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeProbeWorkingDirectoryTests {
    @Test
    func `probe working directory disables deep link registration`() throws {
        let directory = try Self.makeTemporaryDirectory()

        try ClaudeStatusProbe.prepareProbeWorkingDirectory(at: directory)

        let settings = try Self.readSettings(from: directory)
        #expect(settings["disableDeepLinkRegistration"] as? String == "disable")
    }

    @Test
    func `probe working directory preserves existing local settings`() throws {
        let directory = try Self.makeTemporaryDirectory()
        let settingsURL = directory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.local.json")
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let existing: [String: Any] = [
            "permissions": [
                "allow": ["Bash(*)"],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: existing)
        try data.write(to: settingsURL)

        try ClaudeStatusProbe.prepareProbeWorkingDirectory(at: directory)

        let settings = try Self.readSettings(from: directory)
        #expect(settings["disableDeepLinkRegistration"] as? String == "disable")
        let permissions = try #require(settings["permissions"] as? [String: Any])
        #expect(permissions["allow"] as? [String] == ["Bash(*)"])
    }

    @Test
    func `probe working directory overwrites invalid local settings`() throws {
        let directory = try Self.makeTemporaryDirectory()
        let settingsURL = directory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.local.json")
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("{".utf8).write(to: settingsURL)

        try ClaudeStatusProbe.prepareProbeWorkingDirectory(at: directory)

        let settings = try Self.readSettings(from: directory)
        #expect(settings["disableDeepLinkRegistration"] as? String == "disable")
    }

    @Test
    func `probe project directory name matches Claude Code encoding`() {
        let cases = [
            (
                "/Users/test/Library/Application Support/CodexBar/ClaudeProbe",
                "-Users-test-Library-Application-Support-CodexBar-ClaudeProbe"),
            (
                "/Users/test.name/t\u{00E9}st_under/Library/Application Support/CodexBar/ClaudeProbe",
                "-Users-test-name-t-st-under-Library-Application-Support-CodexBar-ClaudeProbe"),
            (
                "/Users/test/emoji_😀/ClaudeProbe",
                "-Users-test-emoji----ClaudeProbe"),
            (
                "/tmp/\(String(repeating: "segment_", count: 40))/ClaudeProbe",
                "-tmp-segment-segment-segment-segment-segment-segment-segment-segment-segment-segment-segment-" +
                    "segment-segment-segment-segment-segment-segment-segment-segment-segment-segment-segment-" +
                    "segment-segment-seg-x9mpdi"),
        ]

        for (path, expected) in cases {
            let directory = URL(fileURLWithPath: path)
            #expect(ClaudeProbeSessionArtifactCleaner.claudeProjectDirectoryName(for: directory) == expected)
        }
    }

    @Test
    func `cleanup removes only probe session jsonl artifacts`() throws {
        let probeDirectory = try Self.makeTemporaryDirectory()
        let claudeRoot = try Self.makeTemporaryDirectory()
        let projectsRoot = claudeRoot.appendingPathComponent("projects", isDirectory: true)
        let probeProject = projectsRoot
            .appendingPathComponent(
                ClaudeProbeSessionArtifactCleaner.claudeProjectDirectoryName(for: probeDirectory),
                isDirectory: true)
        let unrelatedProject = projectsRoot.appendingPathComponent("unrelated-project", isDirectory: true)
        try FileManager.default.createDirectory(at: probeProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelatedProject, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: probeDirectory)
            try? FileManager.default.removeItem(at: claudeRoot)
        }

        let probeSession = probeProject.appendingPathComponent("probe-session.jsonl")
        let probeNote = probeProject.appendingPathComponent("keep.txt")
        let unrelatedSession = unrelatedProject.appendingPathComponent("user-session.jsonl")
        try Data("{}\n".utf8).write(to: probeSession)
        try Data("keep".utf8).write(to: probeNote)
        try Data("{}\n".utf8).write(to: unrelatedSession)

        let removed = ClaudeProbeSessionArtifactCleaner.cleanupProbeSessionArtifacts(
            probeDirectory: probeDirectory,
            environment: ["CLAUDE_CONFIG_DIR": claudeRoot.path, "HOME": claudeRoot.path])

        #expect(removed.map(\.lastPathComponent) == ["probe-session.jsonl"])
        #expect(!FileManager.default.fileExists(atPath: probeSession.path))
        #expect(FileManager.default.fileExists(atPath: probeNote.path))
        #expect(FileManager.default.fileExists(atPath: unrelatedSession.path))
    }

    @Test
    func `cleanup removes hashed long probe project artifacts`() throws {
        let probeDirectory = URL(fileURLWithPath: "/tmp/\(String(repeating: "segment_", count: 40))/ClaudeProbe")
        let claudeRoot = try Self.makeTemporaryDirectory()
        let projectsRoot = claudeRoot.appendingPathComponent("projects", isDirectory: true)
        let probeProject = projectsRoot
            .appendingPathComponent(
                ClaudeProbeSessionArtifactCleaner.claudeProjectDirectoryName(for: probeDirectory),
                isDirectory: true)
        try FileManager.default.createDirectory(at: probeProject, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: claudeRoot)
        }

        let probeSession = probeProject.appendingPathComponent("probe-session.jsonl")
        try Data("{}\n".utf8).write(to: probeSession)

        let removed = ClaudeProbeSessionArtifactCleaner.cleanupProbeSessionArtifacts(
            probeDirectory: probeDirectory,
            environment: ["CLAUDE_CONFIG_DIR": claudeRoot.path, "HOME": claudeRoot.path])

        #expect(removed.map(\.lastPathComponent) == ["probe-session.jsonl"])
        #expect(!FileManager.default.fileExists(atPath: probeSession.path))
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-claude-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func readSettings(from directory: URL) throws -> [String: Any] {
        let settingsURL = directory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.local.json")
        let data = try Data(contentsOf: settingsURL)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
