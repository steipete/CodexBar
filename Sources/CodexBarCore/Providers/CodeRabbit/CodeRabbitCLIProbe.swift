import Foundation

public struct CodeRabbitCLIProbe: Sendable {
    private static let commandTimeout: TimeInterval = 15
    private let usageArguments: [String]
    private let authStatusArguments: [String]

    public init(
        usageArguments: [String] = ["usage"],
        authStatusArguments: [String] = ["auth", "status"])
    {
        self.usageArguments = usageArguments
        self.authStatusArguments = authStatusArguments
    }

    public func fetch(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()) async throws -> CodeRabbitUsageSnapshot
    {
        let loginPATH = LoginShellPathCache.shared.current
        guard let executable = BinaryLocator.resolveCoderabbitBinary(env: environment, loginPATH: loginPATH) else {
            throw SubprocessRunnerError.binaryNotFound("coderabbit")
        }

        var commandEnvironment = environment
        commandEnvironment["NO_COLOR"] = "1"
        commandEnvironment["PATH"] = PathBuilder.effectivePATH(
            purposes: [.tty, .nodeTooling],
            env: environment,
            loginPATH: loginPATH)

        let usageResult = try await SubprocessRunner.run(
            binary: executable,
            arguments: self.usageArguments,
            environment: commandEnvironment,
            timeout: Self.commandTimeout,
            standardInput: FileHandle.nullDevice,
            label: "coderabbit-usage")

        let usageOutput = usageResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? usageResult.stderr
            : usageResult.stdout

        guard !usageOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodeRabbitUsageError.parseFailed("The CodeRabbit CLI returned no usage data.")
        }

        var authOutput: String?
        if let authResult = try? await SubprocessRunner.run(
            binary: executable,
            arguments: self.authStatusArguments,
            environment: commandEnvironment,
            timeout: Self.commandTimeout,
            standardInput: FileHandle.nullDevice,
            label: "coderabbit-auth-status")
        {
            let out = authResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? authResult.stderr
                : authResult.stdout
            if !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                authOutput = out
            }
        }

        return try CodeRabbitUsageParser.parse(
            usageText: usageOutput,
            authText: authOutput,
            now: now)
    }
}
