import Foundation

public enum CodexWindowKeepAliveError: LocalizedError, Sendable {
    case codexNotInstalled
    case launchBlocked(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .codexNotInstalled:
            "Codex CLI missing. Install via `npm i -g @openai/codex` (or bun install) and restart."
        case let .launchBlocked(message):
            message
        case let .failed(message):
            message
        }
    }
}

/// Sends one tiny non-interactive Codex prompt so the next 5-hour usage window starts immediately
/// after the previous one expires. Opt-in only; see `docs/refresh-loop.md`.
///
/// Provider-specific by design: this launches the Codex CLI (`codex exec`) on the user's behalf.
public enum CodexWindowKeepAliveRunner {
    public static let prompt = "ping"
    public static let defaultTimeout: TimeInterval = 120

    /// `codex exec --skip-git-repo-check --json "ping"` plus a read-only sandbox so the one-off session can
    /// never modify files even if the model decides to run a command.
    public static func arguments(prompt: String = Self.prompt) -> [String] {
        ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--json", prompt]
    }

    /// Scratch working directory outside any Git repository, so the ping carries no project context.
    static func workingDirectoryURL(fileManager: FileManager = .default) -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("codexbar-window-keepalive", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Resolves the Codex CLI like the RPC client does (`CODEX_CLI_PATH`, login-shell PATH, bundled desktop
    /// copies) and runs the ping to completion. Throws when Codex is missing, throttled after a recent launch
    /// failure, times out, or exits non-zero.
    public static func run(
        environment: [String: String],
        timeout: TimeInterval = Self.defaultTimeout) async throws
    {
        try await self.run(
            environment: environment,
            timeout: timeout,
            resolveExecutable: defaultCodexExecutableResolver)
    }

    static func run(
        environment: [String: String],
        timeout: TimeInterval,
        resolveExecutable: CodexExecutableResolver) async throws
    {
        guard let resolution = resolveExecutable(environment, "codex") else {
            throw CodexWindowKeepAliveError.codexNotInstalled
        }
        let executable = resolution.executable
        if let message = CodexCLILaunchGate.shared.backgroundSkipMessage(binary: executable) {
            throw CodexWindowKeepAliveError.launchBlocked(message)
        }

        var env = environment
        env["PATH"] = PathBuilder.effectivePATH(
            purposes: [.rpc, .nodeTooling],
            env: env,
            loginPATH: resolution.loginPATH ?? LoginShellPathCache.shared.current)

        do {
            _ = try await SubprocessRunner.run(
                binary: "/usr/bin/env",
                arguments: [executable] + self.arguments(),
                environment: env,
                timeout: timeout,
                currentDirectoryURL: self.workingDirectoryURL(),
                label: "codex-window-keepalive")
        } catch let error as SubprocessRunnerError {
            if case let .launchFailed(details) = error {
                CodexCLILaunchGate.shared.recordLaunchFailure(binary: executable, message: details)
            }
            throw CodexWindowKeepAliveError.failed(error.localizedDescription)
        } catch {
            throw CodexWindowKeepAliveError.failed(error.localizedDescription)
        }
    }
}
