import CodexBarCore
import Foundation

@MainActor
struct CodexAppServerDaemon {
    private struct PIDRecord: Decodable { let pid: Int32 }
    private struct Version: Decodable {
        let status: String
        let backend: String?
        let socketPath: String
    }

    var isAppServerProcess: (Int32) -> Bool = CodexHomeScope.isAppServerProcess
    var run: (String, [String: String]) async throws -> String = Self.runCommand

    func restartIfRunning(homeURL: URL, environment: [String: String]) async -> String? {
        let home = homeURL.resolvingSymlinksInPath().standardizedFileURL
        // Codex uses separate PID records for legacy and daemon-owned installations.
        let running = ["daemon.pid", "app-server.pid"].contains { name in
            let url = home.appendingPathComponent("app-server-daemon/\(name)")
            guard let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(PIDRecord.self, from: data)
            else { return false }
            return self.isAppServerProcess(record.pid)
        }
        guard running else { return nil }
        let env = CodexHomeScope.scopedEnvironment(base: environment, codexHome: home.path)
        let log = CodexBarLog.logger("codex-account-promotion")
        var phase = "detect"
        do {
            let output = try await self.run("version", env)
            let version = try JSONDecoder().decode(Version.self, from: Data(output.utf8))
            // The CLI validates its PID/start-time record and probes this home's control socket.
            guard version.status == "running", version.backend == "pid",
                  URL(fileURLWithPath: version.socketPath).resolvingSymlinksInPath().standardizedFileURL ==
                  home.appendingPathComponent("app-server-control/app-server-control.sock")
            else { return nil }
            phase = "restart"
            _ = try await self.run("restart", env)
            log.info("Codex daemon restarted after account promotion")
            return nil
        } catch {
            log.warning("Codex daemon refresh failed", metadata: ["phase": phase])
            return L("Account switched; restart the Codex background server manually.")
        }
    }

    private static func runCommand(_ command: String, environment: [String: String]) async throws -> String {
        var env = environment
        let loginPATH = LoginShellPathCache.shared.current
        env["PATH"] = PathBuilder.effectivePATH(purposes: [.rpc, .nodeTooling], env: env, loginPATH: loginPATH)
        guard let binary = BinaryLocator.resolveCodexBinary(env: env, loginPATH: loginPATH) else {
            // Provider-specific by design: this operation requires the Codex CLI.
            throw SubprocessRunnerError.binaryNotFound("codex")
        }
        let arguments = ["app-server", "daemon", command]
        let result = if command == "restart" {
            // Once launched, let the CLI finish its external mutation even if the menu task is cancelled.
            try await SubprocessRunner.runToCompletion(
                binary: binary, arguments: arguments, environment: env, label: "codex-daemon-restart")
        } else {
            try await SubprocessRunner.run(
                binary: binary, arguments: arguments, environment: env, timeout: 10, label: "codex-daemon-version")
        }
        return result.stdout
    }
}
