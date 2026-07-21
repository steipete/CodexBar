import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeConfigPathsTests {
    @Test
    func `custom profile prefers config json and otherwise uses local claude json`() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = [ClaudeConfigPaths.configDirectoryEnvironmentKey: root.path]
        let legacy = root.appendingPathComponent(".claude.json")
        let profile = root.appendingPathComponent(".config.json")

        #expect(ClaudeConfigPaths.accountConfigURL(environment: environment) == legacy)

        try Data("{}".utf8).write(to: profile)
        #expect(ClaudeConfigPaths.accountConfigURL(environment: environment) == profile)
    }

    @Test
    func `default profile uses home claude data and home account fallback`() throws {
        let home = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dataRoot = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        let environment = ["HOME": home.path]

        #expect(ClaudeConfigPaths.configRoot(environment: environment) == dataRoot)
        #expect(ClaudeConfigPaths.accountConfigURL(environment: environment) == home.appendingPathComponent(
            ".claude.json"))

        let profile = dataRoot.appendingPathComponent(".config.json")
        try Data("{}".utf8).write(to: profile)
        #expect(ClaudeConfigPaths.accountConfigURL(environment: environment) == profile)
    }

    @Test
    func `secure storage root owns credentials independently of config root`() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let config = root.appendingPathComponent("config", isDirectory: true)
        let secure = root.appendingPathComponent("secure", isDirectory: true)
        let base = [
            "HOME": home.path,
            ClaudeConfigPaths.configDirectoryEnvironmentKey: config.path,
        ]

        #expect(ClaudeConfigPaths.credentialsURL(environment: base) == config.appendingPathComponent(
            ".credentials.json"))

        var explicitSecure = base
        explicitSecure[ClaudeConfigPaths.secureStorageDirectoryEnvironmentKey] = secure.path
        #expect(ClaudeConfigPaths.credentialsURL(environment: explicitSecure) == secure.appendingPathComponent(
            ".credentials.json"))

        var emptySecure = base
        emptySecure[ClaudeConfigPaths.secureStorageDirectoryEnvironmentKey] = ""
        #expect(ClaudeConfigPaths.credentialsURL(environment: emptySecure) == home
            .appendingPathComponent(".claude/.credentials.json"))
    }

    @Test
    func `config directory is one literal path rather than a list`() throws {
        let parent = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let literal = parent.appendingPathComponent("first, second", isDirectory: true)
        let environment = [ClaudeConfigPaths.configDirectoryEnvironmentKey: literal.path]

        #expect(ClaudeConfigPaths.configRoot(environment: environment) == literal.standardizedFileURL)
        #expect(ClaudeConfigPaths.credentialsURL(environment: environment) == literal.appendingPathComponent(
            ".credentials.json"))
    }

    @Test
    func `relative literal roots resolve from the Claude owner working directory`() throws {
        let parent = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let workingDirectory = parent.appendingPathComponent("probe", isDirectory: true)
        let relativeConfig = "first, second"
        let configRoot = workingDirectory.appendingPathComponent(relativeConfig, isDirectory: true)
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        let profile = configRoot.appendingPathComponent(".config.json")
        try Data("{}".utf8).write(to: profile)
        let environment = [ClaudeConfigPaths.configDirectoryEnvironmentKey: relativeConfig]

        #expect(ClaudeConfigPaths.configRoot(
            environment: environment,
            workingDirectory: workingDirectory) == configRoot.standardizedFileURL)
        #expect(ClaudeConfigPaths.accountConfigURL(
            environment: environment,
            workingDirectory: workingDirectory) == profile.standardizedFileURL)
        #expect(ClaudeConfigPaths.credentialsURL(
            environment: environment,
            workingDirectory: workingDirectory) == configRoot.appendingPathComponent(".credentials.json"))

        let tildeEnvironment = [ClaudeConfigPaths.configDirectoryEnvironmentKey: "~/.claude-profile"]
        #expect(ClaudeConfigPaths.configRoot(
            environment: tildeEnvironment,
            workingDirectory: workingDirectory) == workingDirectory
            .appendingPathComponent("~/.claude-profile", isDirectory: true)
            .standardizedFileURL)
    }

    @Test
    func `empty config and secure roots follow relative HOME from the owner working directory`() throws {
        let parent = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let workingDirectory = parent.appendingPathComponent("probe", isDirectory: true)
        let environment = [
            "HOME": "relative-home",
            ClaudeConfigPaths.configDirectoryEnvironmentKey: "",
            ClaudeConfigPaths.secureStorageDirectoryEnvironmentKey: "",
        ]
        let home = workingDirectory.appendingPathComponent("relative-home", isDirectory: true)

        #expect(ClaudeConfigPaths.homeDirectory(
            environment: environment,
            workingDirectory: workingDirectory) == home.standardizedFileURL)
        #expect(ClaudeConfigPaths.configRoot(
            environment: environment,
            workingDirectory: workingDirectory) == home.appendingPathComponent(".claude", isDirectory: true))
        #expect(ClaudeConfigPaths.accountConfigURL(
            environment: environment,
            workingDirectory: workingDirectory) == home.appendingPathComponent(".claude.json"))
        #expect(ClaudeConfigPaths.credentialsURL(
            environment: environment,
            workingDirectory: workingDirectory) == home.appendingPathComponent(".claude/.credentials.json"))
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-claude-paths-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
