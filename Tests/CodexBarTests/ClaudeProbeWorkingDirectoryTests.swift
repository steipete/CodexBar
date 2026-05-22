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
