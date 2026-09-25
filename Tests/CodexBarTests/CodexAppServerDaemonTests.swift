import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized, CodexCredentialFixtures())
@MainActor
struct CodexAppServerDaemonTests {
    @Test
    func `process matching excludes stdio probes and other executables`() {
        #expect(CodexHomeScope.isAppServer(arguments: ["/package/bin/codex", "app-server", "--listen", "unix://"]))
        #expect(!CodexHomeScope.isAppServer(arguments: ["/package/bin/codex", "app-server"]))
        #expect(!CodexHomeScope.isAppServer(arguments: ["/package/bin/node", "app-server", "--listen", "unix://"]))
        #expect(!CodexHomeScope.isAppServer(arguments: ["codex", "exec", "app-server", "--listen", "unix://"]))
        #expect(!CodexHomeScope.isAppServer(arguments: []))
    }

    @Test(arguments: ["daemon.pid", "app-server.pid"])
    func `promotion restarts the live home daemon once after publishing auth`(_ filename: String) async throws {
        let container = try CodexAccountPromotionTestContainer(suiteName: "daemon-promotion")
        defer { container.tearDown() }
        let target = try container.createManagedAccount(
            persistedEmail: "managed@example.com", authAccountID: "acct-managed")
        try container.persistAccounts([target])
        _ = try container.writeLiveOAuthAuthFile(email: "live@example.com", accountID: "acct-live")
        try Self.writePID(home: container.liveHomeURL, filename: filename)
        var calls: [String] = []
        let daemon = CodexAppServerDaemon(isAppServerProcess: { $0 == 123 }, run: { command, env in
            calls.append(command)
            #expect(env["CODEX_HOME"] == container.liveHomeURL.resolvingSymlinksInPath().path)
            let identity = try container.identityReader.loadAccountIdentity(homePath: container.liveHomeURL.path)
            #expect(identity.email == "managed@example.com")
            return Self.version(home: container.liveHomeURL)
        })
        let result = try await container.makeService(daemon: daemon).promoteManagedAccount(id: target.id)
        #expect(result.outcome == .promoted)
        #expect(result.daemonRestartNote == nil)
        #expect(calls == ["version", "restart"])
    }

    @Test(arguments: [false, true])
    func `absent or stale daemon does not invoke the CLI`(_ stale: Bool) async throws {
        let container = try CodexAccountPromotionTestContainer(suiteName: "daemon-absent")
        defer { container.tearDown() }
        if stale { try Self.writePID(home: container.liveHomeURL) }
        let daemon = CodexAppServerDaemon(isAppServerProcess: { _ in false }, run: { _, _ in
            Issue.record("Should not invoke the CLI without a matching process")
            return ""
        })
        let note = await daemon.restartIfRunning(homeURL: container.liveHomeURL, environment: [:])
        #expect(note == nil)
    }

    @Test(arguments: ["version", "restart"])
    func `unsupported daemon command or restart failure preserves promotion with a note`(
        _ failure: String) async throws
    {
        let container = try CodexAccountPromotionTestContainer(suiteName: "daemon-failure")
        defer { container.tearDown() }
        let target = try container.createManagedAccount(
            persistedEmail: "managed@example.com", authAccountID: "acct-managed")
        try container.persistAccounts([target])
        try Self.writePID(home: container.liveHomeURL)
        var calls: [String] = []
        let daemon = CodexAppServerDaemon(isAppServerProcess: { _ in true }, run: { command, _ in
            calls.append(command)
            if command == failure {
                throw SubprocessRunnerError.nonZeroExit(code: 2, stderr: "synthetic command failure")
            }
            return Self.version(home: container.liveHomeURL)
        })
        let coordinator = CodexAccountPromotionCoordinator(service: container.makeService(daemon: daemon))
        let result = try await coordinator.promote(managedAccountID: target.id).get()
        #expect(result.outcome == .promoted)
        #expect(result.didMutateLiveAuth)
        #expect(container.settings.codexActiveSource == .liveSystem)
        #expect(result.daemonRestartNote == "Account switched; restart the Codex background server manually.")
        #expect(coordinator.daemonRestartNote == result.daemonRestartNote)
        let menu = MenuDescriptor.build(
            provider: .codex,
            store: container.usageStore,
            settings: container.settings,
            account: AccountInfo(email: nil, plan: nil),
            codexAccountPromotionCoordinator: coordinator,
            updateReady: false)
        #expect(menu.sections.flatMap(\.entries).contains {
            if case let .text(text, _) = $0 { return text == result.daemonRestartNote }
            return false
        })
        #expect(calls == (failure == "version" ? ["version"] : ["version", "restart"]))
    }

    @Test(arguments: ["other-home", "unmanaged", "stopped"])
    func `only a managed daemon answering for the promoted home can restart`(_ mismatch: String) async throws {
        let container = try CodexAccountPromotionTestContainer(suiteName: "daemon-home-match")
        defer { container.tearDown() }
        try Self.writePID(home: container.liveHomeURL)
        var calls: [String] = []
        let daemon = CodexAppServerDaemon(isAppServerProcess: { _ in true }, run: { command, env in
            calls.append(command)
            #expect(env["HOME"] == "/synthetic-user")
            let home = mismatch == "other-home" ? container.managedHomesURL : container.liveHomeURL
            return Self.version(
                home: home,
                backend: mismatch == "unmanaged" ? "" : "pid",
                status: mismatch == "stopped" ? "notRunning" : "running")
        })
        let note = await daemon.restartIfRunning(
            homeURL: container.liveHomeURL, environment: ["HOME": "/synthetic-user", "CODEX_HOME": "/wrong-home"])
        #expect(note == nil)
        #expect(calls == ["version"])
    }

    private static func writePID(home: URL, filename: String = "daemon.pid") throws {
        let directory = home.appendingPathComponent("app-server-daemon")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"pid":123,"processStartTime":"synthetic"}"#.utf8)
            .write(to: directory.appendingPathComponent(filename))
    }

    private static func version(home: URL, backend: String = "pid", status: String = "running") -> String {
        let socket = home.resolvingSymlinksInPath().appendingPathComponent("app-server-control/app-server-control.sock")
        return "{\"status\":\"\(status)\",\"backend\":\"\(backend)\",\"socketPath\":\"\(socket.path)\"}"
    }
}
