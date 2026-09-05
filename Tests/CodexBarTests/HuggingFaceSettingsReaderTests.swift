import Foundation
import Testing
@testable import CodexBarCore

struct HuggingFaceSettingsReaderTests {
    @Test
    func `environment credentials use canonical precedence and cleaning`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let explicitPath = root.appendingPathComponent("explicit/token")
        try Self.write("  'file-token'  \n", to: explicitPath)

        var environment = [
            HuggingFaceSettingsReader.tokenEnvironmentKey: "  \" env-token \"  ",
            HuggingFaceSettingsReader.hubTokenEnvironmentKey: "  'hub-token'  ",
            HuggingFaceSettingsReader.tokenPathEnvironmentKey: explicitPath.path,
        ]
        #expect(Self.token(environment, homeDirectory: root) == "env-token")

        environment[HuggingFaceSettingsReader.tokenEnvironmentKey] = "  \"  \"  "
        #expect(Self.token(environment, homeDirectory: root) == "hub-token")

        environment.removeValue(forKey: HuggingFaceSettingsReader.hubTokenEnvironmentKey)
        #expect(Self.token(environment, homeDirectory: root) == "file-token")
    }

    @Test
    func `token file selectors follow explicit HF paths and tilde expansion`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let explicitPath = root.appendingPathComponent("explicit/token")
        let hfHome = root.appendingPathComponent("hf-home")
        let cacheHome = root.appendingPathComponent("cache-home")
        try Self.write("explicit-token\n", to: explicitPath)
        try Self.write("hf-home-token\n", to: hfHome.appendingPathComponent("token"))
        try Self.write("cache-token\n", to: cacheHome.appendingPathComponent("huggingface/token"))
        try Self.write("default-token\n", to: root.appendingPathComponent(".cache/huggingface/token"))

        var environment = [
            HuggingFaceSettingsReader.tokenPathEnvironmentKey: "  \"~/explicit/token\"  ",
            HuggingFaceSettingsReader.homeEnvironmentKey: hfHome.path,
            HuggingFaceSettingsReader.cacheHomeEnvironmentKey: cacheHome.path,
        ]
        #expect(Self.token(environment, homeDirectory: root) == "explicit-token")

        environment.removeValue(forKey: HuggingFaceSettingsReader.tokenPathEnvironmentKey)
        #expect(Self.token(environment, homeDirectory: root) == "hf-home-token")

        environment.removeValue(forKey: HuggingFaceSettingsReader.homeEnvironmentKey)
        #expect(Self.token(environment, homeDirectory: root) == "cache-token")

        environment.removeValue(forKey: HuggingFaceSettingsReader.cacheHomeEnvironmentKey)
        #expect(Self.token(environment, homeDirectory: root) == "default-token")
    }

    @Test
    func `selected missing empty and non-file paths do not fall through`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fallbackHome = root.appendingPathComponent("fallback")
        try Self.write("fallback-token\n", to: fallbackHome.appendingPathComponent("token"))
        let missingPath = root.appendingPathComponent("missing/token")
        var environment = [
            HuggingFaceSettingsReader.tokenPathEnvironmentKey: missingPath.path,
            HuggingFaceSettingsReader.homeEnvironmentKey: fallbackHome.path,
        ]
        #expect(Self.token(environment, homeDirectory: root) == nil)

        let emptyPath = root.appendingPathComponent("empty/token")
        try Self.write("  \"  \"  \n", to: emptyPath)
        environment[HuggingFaceSettingsReader.tokenPathEnvironmentKey] = emptyPath.path
        #expect(Self.token(environment, homeDirectory: root) == nil)

        let directoryPath = root.appendingPathComponent("directory-token")
        try FileManager.default.createDirectory(at: directoryPath, withIntermediateDirectories: true)
        environment[HuggingFaceSettingsReader.tokenPathEnvironmentKey] = directoryPath.path
        #expect(Self.token(environment, homeDirectory: root) == nil)
    }

    @Test
    func `file credentials use the first cleaned token line`() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tokenPath = root.appendingPathComponent("token")
        try Self.write("  'file-token'  \nignored-line\n", to: tokenPath)
        #expect(Self.token([
            HuggingFaceSettingsReader.tokenPathEnvironmentKey: tokenPath.path,
        ], homeDirectory: root) == "file-token")

        try Self.write("  \"  \"  \n", to: tokenPath)
        #expect(Self.token([
            HuggingFaceSettingsReader.tokenPathEnvironmentKey: tokenPath.path,
        ], homeDirectory: root) == nil)
    }

    private static func token(_ environment: [String: String], homeDirectory: URL) -> String? {
        HuggingFaceSettingsReader.token(environment: environment, homeDirectory: homeDirectory)
    }

    private static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HuggingFaceSettingsReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try value.write(to: url, atomically: true, encoding: .utf8)
    }
}
