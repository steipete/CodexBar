import Foundation
import Testing
@testable import CodexBar

struct CodexAppServerDaemonReloaderTests {
    @Test
    func `missing Codex binary leaves daemon untouched`() async {
        let reloader = DefaultCodexAppServerDaemonReloader(
            baseEnvironment: [:],
            binaryResolver: { _ in nil })

        #expect(await reloader.reloadAfterAuthPromotion() == .unavailable)
    }

    @Test
    func `failed version probe does not attempt a restart`() async {
        let recorder = DaemonCommandRecorder(failingArguments: ["app-server", "daemon", "version"])
        let reloader = Self.makeReloader(recorder: recorder)

        #expect(await reloader.reloadAfterAuthPromotion() == .notRunning)
        #expect(await recorder.arguments == [["app-server", "daemon", "version"]])
    }

    @Test
    func `running daemon restarts after auth promotion`() async {
        let recorder = DaemonCommandRecorder()
        let reloader = Self.makeReloader(recorder: recorder)

        #expect(await reloader.reloadAfterAuthPromotion() == .restarted)
        #expect(await recorder.arguments == [
            ["app-server", "daemon", "version"],
            ["app-server", "daemon", "restart"],
        ])
    }

    @Test
    func `remote control setting preserves remote control mode`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-daemon-reloader-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsDirectory = root.appendingPathComponent("app-server-daemon", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        try #"{"remoteControlEnabled":true}"#.write(
            to: settingsDirectory.appendingPathComponent("settings.json"),
            atomically: true,
            encoding: .utf8)

        let recorder = DaemonCommandRecorder()
        let reloader = Self.makeReloader(
            baseEnvironment: ["CODEX_HOME": root.path],
            recorder: recorder)

        #expect(await reloader.reloadAfterAuthPromotion() == .remoteControlRestarted)
        #expect(await recorder.arguments == [
            ["app-server", "daemon", "version"],
            ["remote-control", "start"],
        ])
    }

    @Test
    func `restart failure returns bounded diagnostic output`() async {
        let output = String(repeating: "x", count: 1200)
        let restart = ["app-server", "daemon", "restart"]
        let recorder = DaemonCommandRecorder(failingArguments: restart, failureOutput: output)
        let reloader = Self.makeReloader(recorder: recorder)

        let outcome = await reloader.reloadAfterAuthPromotion()

        guard case let .failed(message) = outcome else {
            Issue.record("Expected restart failure, got \(outcome)")
            return
        }
        #expect(message.count == 1000)
        #expect(message == String(output.prefix(1000)))
    }

    private static func makeReloader(
        baseEnvironment: [String: String] = [:],
        recorder: DaemonCommandRecorder) -> DefaultCodexAppServerDaemonReloader
    {
        DefaultCodexAppServerDaemonReloader(
            baseEnvironment: baseEnvironment,
            binaryResolver: { _ in "/usr/bin/true" },
            commandRunner: { _, arguments, _, _ in
                try await recorder.run(arguments: arguments)
            })
    }
}

private actor DaemonCommandRecorder {
    private(set) var arguments: [[String]] = []
    private let failingArguments: [String]?
    private let failureOutput: String

    init(failingArguments: [String]? = nil, failureOutput: String = "command failed") {
        self.failingArguments = failingArguments
        self.failureOutput = failureOutput
    }

    func run(arguments: [String]) throws -> String {
        self.arguments.append(arguments)
        if arguments == self.failingArguments {
            throw DaemonCommandTestError.failed(self.failureOutput)
        }
        return ""
    }
}

private enum DaemonCommandTestError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message): message
        }
    }
}
