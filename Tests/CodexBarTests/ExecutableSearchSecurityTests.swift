import Foundation
import Testing
@testable import CodexBarCore

struct ExecutableSearchSecurityTests {
    @Test
    func `plugin resources cannot come from an unrelated app bundle`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Unrelated.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try #require(CodexBarCoreResources.bundle)
        try FileManager.default.copyItem(
            at: source.bundleURL.resolvingSymlinksInPath(),
            to: resources.appendingPathComponent("CodexBar_CodexBarCore.bundle"))
        let resolved = try CodexBarCoreResources.resolve(
            mainBundle: #require(Bundle(url: app)),
            executableURL: root.appendingPathComponent("real-binary"),
            swiftPMBuildDirectory: nil)
        #expect(resolved == nil)
    }

    @Test
    func `implicit lookup ignores relative PATH entries`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let planted = root.appendingPathComponent("synthetic-tool")
        try FakeExecutable.install("printf planted", at: planted)
        let relativeDirectory = String(repeating: "../", count: URL(fileURLWithPath: FileManager.default
                .currentDirectoryPath).pathComponents.count - 1) + root.path.dropFirst()
        #expect(FileManager.default.isExecutableFile(atPath: relativeDirectory + "/synthetic-tool"))
        let found = BinaryLocator.resolveBinary(
            name: "synthetic-tool",
            overrideKey: "SYNTHETIC_TOOL_PATH",
            env: ["PATH": relativeDirectory],
            loginPATH: [".", relativeDirectory],
            commandV: { _, _, _, _ in nil },
            aliasResolver: { _, _, _, _, _ in nil },
            fileManager: .default,
            home: root.path)
        #expect(found == nil)
    }

    @Test
    func `explicit relative shell and PTY executables remain usable`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let planted = root.appendingPathComponent("synthetic-tool")
        try FakeExecutable.install("printf planted", at: planted)
        let relative = String(repeating: "../", count: URL(fileURLWithPath: FileManager.default
                .currentDirectoryPath).pathComponents.count - 1) + planted.path.dropFirst()
        let shell = try #require(ShellCommandLocator.test_runShellCommand(
            shell: relative, arguments: [], timeout: 5))
        #expect(String(data: shell, encoding: .utf8) == "planted")
        #expect(TTYCommandRunner.which(relative) == planted.standardizedFileURL.path)
        let result = try TTYCommandRunner().run(
            binary: relative,
            send: "",
            options: .init(timeout: 5, baseEnvironment: ["PATH": "/usr/bin:/bin"], initialDelay: 0))
        #expect(result.text == "planted")
    }

    @Test
    func `tailscale candidates exclude relative search directories`() {
        let candidates = RemoteSessionFetcher.tailscaleBinaryCandidates(path: ":.:tools:/usr/bin")
        #expect(candidates.allSatisfy { $0.hasPrefix("/") })
        #expect(candidates.contains("/usr/bin/tailscale"))
    }

    @Test
    func `child PATH removes working directory entries and retains absolute install paths`() {
        let path = PathBuilder.effectivePATH(
            purposes: [.tty],
            env: ["PATH": ":.:tools:../bin:/usr/bin:"],
            loginPATH: ["", ".", "bin", "/custom/bin"])
        #expect(path == "/custom/bin:/usr/bin")
        #expect(PathBuilder.effectivePATH(purposes: [.rpc], env: ["PATH": ".:bin:"], loginPATH: nil)
            == "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test
    func `child interpreter search ignores a planted relative PATH directory`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let relative = String(repeating: "../", count: URL(fileURLWithPath: FileManager.default
                .currentDirectoryPath).pathComponents.count - 1) + root.path.dropFirst()
        try FakeExecutable.install("printf planted", at: root.appendingPathComponent("synthetic-tool"))
        let trusted = root.appendingPathComponent("trusted")
        try FileManager.default.createDirectory(at: trusted, withIntermediateDirectories: true)
        try FakeExecutable.install("printf trusted", at: trusted.appendingPathComponent("synthetic-tool"))
        let result = try await SubprocessRunner.run(
            binary: "/usr/bin/env",
            arguments: ["synthetic-tool"],
            environment: ["PATH": relative + ":" + trusted.path],
            timeout: 5,
            label: "synthetic PATH fixture")
        #expect(result.stdout == "trusted")
    }

    @Test
    func `explicit relative subprocess executable remains usable`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let planted = root.appendingPathComponent("synthetic-tool")
        try FakeExecutable.install("printf planted", at: planted)
        let relative = String(repeating: "../", count: URL(fileURLWithPath: FileManager.default
                .currentDirectoryPath).pathComponents.count - 1) + planted.path.dropFirst()
        let result = try await SubprocessRunner.run(
            binary: relative,
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: 5,
            currentDirectoryURL: root,
            label: "synthetic explicit executable fixture")
        #expect(result.stdout == "planted")
    }
}
