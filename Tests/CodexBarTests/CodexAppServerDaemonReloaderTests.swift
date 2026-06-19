import CodexBarCore
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
    func `missing daemon socket leaves daemon untouched`() async {
        let recorder = DaemonCommandRecorder(
            failingArguments: ["app-server", "daemon", "version"],
            failure: SubprocessRunnerError.nonZeroExit(
                code: 1,
                stderr: "failed to connect: No such file or directory (os error 2)"))
        let reloader = Self.makeReloader(recorder: recorder)

        #expect(await reloader.reloadAfterAuthPromotion() == .notRunning)
        #expect(await recorder.arguments == [["app-server", "daemon", "version"]])
    }

    @Test
    func `probe timeout fails instead of accepting stale daemon state`() async {
        let recorder = DaemonCommandRecorder(
            failingArguments: ["app-server", "daemon", "version"],
            failure: SubprocessRunnerError.timedOut("daemon probe"))
        let reloader = Self.makeReloader(recorder: recorder)

        #expect(await reloader.reloadAfterAuthPromotion() == .failed("Command timed out: daemon probe"))
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
        #expect(await recorder.timeouts == [90, 90])
    }

    @Test
    func `restart failure returns bounded diagnostic output`() async {
        let output = String(repeating: "x", count: 1200)
        let restart = ["app-server", "daemon", "restart"]
        let recorder = DaemonCommandRecorder(
            failingArguments: restart,
            failure: DaemonCommandTestError.failed(output))
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
            commandRunner: { _, arguments, _, timeout in
                try await recorder.run(arguments: arguments, timeout: timeout)
            })
    }
}

private actor DaemonCommandRecorder {
    private(set) var arguments: [[String]] = []
    private(set) var timeouts: [TimeInterval] = []
    private let failingArguments: [String]?
    private let failure: Error

    init(
        failingArguments: [String]? = nil,
        failure: Error = DaemonCommandTestError.failed("command failed"))
    {
        self.failingArguments = failingArguments
        self.failure = failure
    }

    func run(arguments: [String], timeout: TimeInterval) throws -> String {
        self.arguments.append(arguments)
        self.timeouts.append(timeout)
        if arguments == self.failingArguments {
            throw self.failure
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
