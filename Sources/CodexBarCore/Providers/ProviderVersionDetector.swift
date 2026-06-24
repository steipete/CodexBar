#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

public enum ProviderVersionDetector {
    public static func claudeVersion() -> String? {
        guard let path = TTYCommandRunner.which("claude") else { return nil }
        do {
            let out = try TTYCommandRunner().run(
                binary: path,
                send: "",
                options: TTYCommandRunner.Options(
                    timeout: 5.0,
                    // `--version` alone makes Claude Code print and exit before it
                    // initializes its credential subsystem. Passing `--allowed-tools`
                    // (even empty) makes it treat the invocation as a real session and
                    // read the OAuth token from the macOS keychain ("Claude Code-credentials"),
                    // which spawns `/usr/bin/security` and triggers a keychain prompt on
                    // every probe when no ~/.claude/.credentials.json / env token exists.
                    extraArgs: ["--version"],
                    initialDelay: 0.0,
                    useClaudeProbeWorkingDirectory: true)).text
            let trimmed = TextParsing.stripANSICodes(out).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }

    public static func codexVersion() -> String? {
        guard let path = TTYCommandRunner.which("codex") else { return nil }
        let candidates = [
            ["--version"],
            ["version"],
            ["-v"],
        ]
        for args in candidates {
            if let version = Self.run(path: path, args: args) { return version }
        }
        return nil
    }

    public static func geminiVersion() -> String? {
        let env = ProcessInfo.processInfo.environment
        guard let path = BinaryLocator.resolveGeminiBinary(env: env, loginPATH: nil)
            ?? TTYCommandRunner.which("gemini") else { return nil }
        let candidates = [
            ["--version"],
            ["-v"],
        ]
        for args in candidates {
            if let version = Self.run(path: path, args: args) { return version }
        }
        return nil
    }

    static func run(
        path: String,
        args: [String],
        timeout: TimeInterval = 2.0,
        environment: [String: String]? = nil,
        mergeStandardError: Bool = false) -> String?
    {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.environment = environment
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = mergeStandardError ? out : FileHandle.nullDevice
        proc.standardInput = nil
        let outputCapture = ProcessPipeCapture(pipe: out)
        outputCapture.start()

        let exitSemaphore = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in
            exitSemaphore.signal()
        }

        do {
            try proc.run()
        } catch {
            outputCapture.stop()
            return nil
        }

        let didExit = exitSemaphore.wait(timeout: .now() + timeout) == .success
        if !didExit, !Self.forceExit(proc, exitSemaphore: exitSemaphore) {
            outputCapture.stop()
            return nil
        }

        let data = outputCapture.finishSynchronously(timeout: 0.25)
        guard proc.terminationStatus == 0,
              let text = ProcessPipeCapture.decodeUTF8(data)
                  .split(whereSeparator: \.isNewline).first
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func forceExit(_ proc: Process, exitSemaphore: DispatchSemaphore) -> Bool {
        guard proc.isRunning else { return true }

        proc.terminate()
        if exitSemaphore.wait(timeout: .now() + 0.5) == .success {
            return true
        }

        guard proc.isRunning else { return true }
        kill(proc.processIdentifier, SIGKILL)
        return exitSemaphore.wait(timeout: .now() + 1.0) == .success
    }
}
