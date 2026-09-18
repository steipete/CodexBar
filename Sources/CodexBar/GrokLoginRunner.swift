import CodexBarCore
import Foundation

enum GrokLoginRunner {
    static let defaultTimeout: TimeInterval = 300

    static func run(
        homePath: String? = nil,
        timeout: TimeInterval = defaultTimeout,
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
        env = GrokHomeScope.scopedEnvironment(base: env, grokHome: homePath)

        return await CLILoginRunner.run(
            executable: BinaryLocator.resolveGrokBinary(env: env, loginPATH: loginPATH),
            extraArguments: ["--device-auth"],
            environment: env,
            timeout: timeout,
            outputDrainTimeout: outputDrainTimeout,
            onProgress: onProgress)
    }
}
