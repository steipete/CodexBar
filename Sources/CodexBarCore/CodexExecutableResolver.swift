import Foundation

struct CodexExecutableResolution: Sendable {
    let executable: String
    let loginPATH: [String]?
}

typealias CodexExecutableResolver = @Sendable (
    _ environment: [String: String],
    _ executable: String) -> CodexExecutableResolution?

private func executableIsScript(_ path: String) -> Bool {
    guard let handle = FileHandle(forReadingAtPath: path) else { return true }
    defer { try? handle.close() }
    return (try? handle.read(upToCount: 2)) == Data("#!".utf8)
}

func resolveCodexExecutableForRPC(
    environment: [String: String],
    executable: String,
    captureLoginPATH: () -> [String]?) -> CodexExecutableResolution?
{
    if let override = environment["CODEX_CLI_PATH"],
       FileManager.default.isExecutableFile(atPath: override)
    {
        // Native overrides can launch directly. Script overrides can depend on a
        // login-shell PATH through `#!/usr/bin/env node` or helper commands.
        let loginPATH = executableIsScript(override) ? captureLoginPATH() : nil
        return CodexExecutableResolution(executable: override, loginPATH: loginPATH)
    }

    // Capture before the general resolver to preserve login-shell PATH precedence
    // over bundled fallbacks and to make `/usr/bin/env node` launchers usable.
    let loginPATH = captureLoginPATH()
    guard let resolved = BinaryLocator.resolveCodexBinary(env: environment, loginPATH: loginPATH)
        ?? TTYCommandRunner.which(executable)
    else { return nil }
    return CodexExecutableResolution(executable: resolved, loginPATH: loginPATH)
}

let defaultCodexExecutableResolver: CodexExecutableResolver = { environment, executable in
    // Resolve the login-shell PATH at the actual RPC launch boundary. Warming it
    // from UsageFetcher.init was both racy for env-based launchers and unsafe for
    // short-lived CLI hosts because the fire-and-forget probe could outlive them.
    resolveCodexExecutableForRPC(
        environment: environment,
        executable: executable,
        captureLoginPATH: {
            LoginShellPathCache.shared.currentOrCapture(shell: environment["SHELL"])
        })
}
