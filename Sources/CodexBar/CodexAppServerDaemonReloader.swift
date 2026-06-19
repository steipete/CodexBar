import CodexBarCore
import Foundation

enum CodexAppServerDaemonReloadOutcome: Equatable, Sendable {
    case notNeeded
    case notRunning
    case restarted
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
        commandTimeout: TimeInterval = 90,
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
            if Self.probeShowsDaemonAbsent(error) {
                return .notRunning
            }
            return .failed(Self.limitedOutput(for: error))
        }

        do {
            _ = try await self.commandRunner(
                executable,
                ["app-server", "daemon", "restart"],
                environment,
                self.commandTimeout)
            return .restarted
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

    private static func probeShowsDaemonAbsent(_ error: Error) -> Bool {
        guard case let SubprocessRunnerError.nonZeroExit(_, stderr) = error else { return false }
        let normalized = stderr.lowercased()
        return normalized.contains("no such file or directory") || normalized.contains("connection refused")
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
