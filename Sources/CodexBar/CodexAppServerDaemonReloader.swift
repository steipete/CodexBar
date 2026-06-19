import CodexBarCore
import Foundation

enum CodexAppServerDaemonReloadOutcome: Equatable, Sendable {
    case notNeeded
    case notRunning
    case restarted
    case unavailable
    case unmanaged
    case failed(String)
}

protocol CodexAppServerDaemonReloading: Sendable {
    func reloadAfterAuthPromotion() async -> CodexAppServerDaemonReloadOutcome
}

struct DefaultCodexAppServerDaemonReloader: CodexAppServerDaemonReloading {
    private struct DaemonVersionResponse: Decodable {
        let status: String
        let backend: String?
    }

    typealias BinaryResolver = @Sendable ([String: String]) -> String?
    typealias CommandRunner = @Sendable (
        _ executable: String,
        _ arguments: [String],
        _ environment: [String: String],
        _ timeout: TimeInterval) async throws -> String
    private let baseEnvironment: [String: String]
    private let probeTimeout: TimeInterval
    private let restartTimeout: TimeInterval
    private let binaryResolver: BinaryResolver
    private let commandRunner: CommandRunner

    init(
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        probeTimeout: TimeInterval = 10,
        restartTimeout: TimeInterval = 120,
        binaryResolver: @escaping BinaryResolver = { environment in
            BinaryLocator.resolveCodexBinary(
                env: environment,
                loginPATH: LoginShellPathCache.shared.current)
        },
        commandRunner: @escaping CommandRunner = Self.runCommand)
    {
        self.baseEnvironment = baseEnvironment
        self.probeTimeout = probeTimeout
        self.restartTimeout = restartTimeout
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

        let versionOutput: String
        do {
            versionOutput = try await self.commandRunner(
                executable,
                ["app-server", "daemon", "version"],
                environment,
                self.probeTimeout)
        } catch {
            if Self.probeShowsDaemonAbsent(error) {
                return .failed("Codex daemon state could not be confirmed while its socket was unavailable.")
            }
            if Self.probeShowsCapabilityUnavailable(error) {
                return .unavailable
            }
            return .failed(Self.limitedOutput(for: error))
        }

        guard let data = versionOutput.data(using: .utf8),
              let response = try? JSONDecoder().decode(DaemonVersionResponse.self, from: data)
        else {
            return .failed("Codex daemon returned an invalid version response.")
        }
        guard response.status == "running" else {
            return .notRunning
        }
        guard response.backend != nil else {
            return .unmanaged
        }

        do {
            _ = try await self.commandRunner(
                executable,
                ["app-server", "daemon", "restart"],
                environment,
                self.restartTimeout)
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
        return result.stdout
    }

    private static func probeShowsDaemonAbsent(_ error: Error) -> Bool {
        guard case let SubprocessRunnerError.nonZeroExit(_, stderr) = error else { return false }
        let normalized = stderr.lowercased()
        return normalized.contains("no such file or directory") || normalized.contains("connection refused")
    }

    private static func probeShowsCapabilityUnavailable(_ error: Error) -> Bool {
        guard case let SubprocessRunnerError.nonZeroExit(code, _) = error else { return false }
        return code == 2
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
