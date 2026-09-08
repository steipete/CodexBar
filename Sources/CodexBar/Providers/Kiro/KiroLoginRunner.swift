import CodexBarCore
import Foundation

enum KiroLoginRunner {
    static func run(
        timeout: TimeInterval = 120,
        outputDrainTimeout: TimeInterval = 3,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        loginPATH: [String]? = LoginShellPathCache.shared.current,
        onProgress: (@Sendable (String) -> Void)? = nil) async -> CLILoginRunner.Result
    {
        var env = environment
        env["PATH"] = PathBuilder.effectivePATH(
            purposes: [.rpc, .tty, .nodeTooling],
            env: env,
            loginPATH: loginPATH)

        return await CLILoginRunner.run(
            executable: BinaryLocator.resolveKiroCLIBinary(env: env, loginPATH: loginPATH),
            environment: env,
            timeout: timeout,
            outputDrainTimeout: outputDrainTimeout,
            onProgress: onProgress)
    }
}
