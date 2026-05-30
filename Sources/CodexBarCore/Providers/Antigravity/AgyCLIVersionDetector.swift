import Foundation

/// Detects the installed Antigravity CLI (`agy`) version.
public enum AgyCLIVersionDetector: Sendable {
    private static let commandTimeout: TimeInterval = 5

    public static func detectVersion(
        env: [String: String] = ProcessInfo.processInfo.environment,
        loginPATH: [String]? = LoginShellPathCache.shared.current) async -> String?
    {
        guard let executable = BinaryLocator.resolveAgyBinary(env: env, loginPATH: loginPATH) else {
            return nil
        }

        let pathEnv = PathBuilder.effectivePATH(
            purposes: [.tty, .nodeTooling],
            env: env,
            loginPATH: loginPATH)

        do {
            let result = try await SubprocessRunner.run(
                binary: executable,
                arguments: ["--version"],
                environment: ["PATH": pathEnv],
                timeout: Self.commandTimeout,
                label: "agy-version")
            let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return version.isEmpty ? nil : version
        } catch {
            return nil
        }
    }
}
