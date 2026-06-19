import CodexBarCore
import Foundation

enum CodexAppServerDaemonReloadOutcome: Equatable, Sendable {
    case notNeeded
    case notRunning
    case restarted
    case remoteControlRestarted
    case unavailable
    case failed(String)
}

protocol CodexAppServerDaemonReloading: Sendable {
    func reloadAfterAuthPromotion() async -> CodexAppServerDaemonReloadOutcome
}

struct DefaultCodexAppServerDaemonReloader: CodexAppServerDaemonReloading {
    typealias BinaryResolver = @Sendable ([String: String]) -> String?
    typealias CommandRunner = @Sendable (
        _ executable: String,
        _ arguments: [String],
        _ environment: [String: String],
        _ timeout: TimeInterval) async throws -> String

    private let baseEnvironment: [String: String]
    private let commandTimeout: TimeInterval
    private let binaryResolver: BinaryResolver
    private let commandRunner: CommandRunner

    init(
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        commandTimeout: TimeInterval = 10,
        binaryResolver: @escaping BinaryResolver = { environment in
            BinaryLocator.resolveCodexBinary(
                env: environment,
                loginPATH: LoginShellPathCache.shared.current)
        },
        commandRunner: @escaping CommandRunner = Self.runCommand)
    {
        self.baseEnvironment = baseEnvironment
        self.commandTimeout = commandTimeout
        self.binaryResolver = binaryResolver
        self.commandRunner = commandRunner
    }

    func reloadAfterAuthPromotion() async -> CodexAppServerDaemonReloadOutcome {
        var environment = self.baseEnvironment
        environment["PATH"] = PathBuilder.effectivePATH(
            purposes: [.rpc, .tty, .nodeTooling],
            env: environment,
            loginPATH: LoginShellPathCache.shared.current)

        guard let executable = self.binaryResolver(environment) else {
            return .unavailable
        }

        do {
            _ = try await self.commandRunner(
                executable,
                ["app-server", "daemon", "version"],
                environment,
                self.commandTimeout)
        } catch {
            return .notRunning
        }

        let remoteControlEnabled = Self.remoteControlEnabled(environment: environment)
        let restartArguments = remoteControlEnabled
            ? ["remote-control", "start"]
            : ["app-server", "daemon", "restart"]

        do {
            _ = try await self.commandRunner(
                executable,
                restartArguments,
                environment,
                self.commandTimeout)
            return remoteControlEnabled ? .remoteControlRestarted : .restarted
        } catch {
            return .failed(Self.limitedOutput(for: error))
        }
    }

    private static func runCommand(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval) async throws -> String
    {
        let result = try await SubprocessRunner.run(
            binary: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout,
            label: "Codex app-server daemon reload")
        return [result.stdout, result.stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func remoteControlEnabled(environment: [String: String]) -> Bool {
        let settingsURL = self.codexHomeURL(environment: environment)
            .appendingPathComponent("app-server-daemon", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(DaemonSettings.self, from: data)
        else {
            return false
        }
        return settings.remoteControlEnabled == true
    }

    private static func codexHomeURL(environment: [String: String]) -> URL {
        if let raw = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    private static func limitedOutput(for error: Error) -> String {
        let output = switch error {
        case let SubprocessRunnerError.nonZeroExit(_, stderr): stderr
        default: error.localizedDescription
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No output captured." : String(trimmed.prefix(1000))
    }
}

private struct DaemonSettings: Decodable {
    let remoteControlEnabled: Bool?
}
