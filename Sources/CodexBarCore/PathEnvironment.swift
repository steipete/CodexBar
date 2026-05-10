import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum PathPurpose: Hashable, Sendable {
    case rpc
    case tty
    case nodeTooling
}

public struct PathDebugSnapshot: Equatable, Sendable {
    public let codexBinary: String?
    public let claudeBinary: String?
    public let geminiBinary: String?
    public let effectivePATH: String
    public let loginShellPATH: String?

    public static let empty = PathDebugSnapshot(
        codexBinary: nil,
        claudeBinary: nil,
        geminiBinary: nil,
        effectivePATH: "",
        loginShellPATH: nil)

    public init(
        codexBinary: String?,
        claudeBinary: String?,
        geminiBinary: String? = nil,
        effectivePATH: String,
        loginShellPATH: String?)
    {
        self.codexBinary = codexBinary
        self.claudeBinary = claudeBinary
        self.geminiBinary = geminiBinary
        self.effectivePATH = effectivePATH
        self.loginShellPATH = loginShellPATH
    }
}

public enum BinaryLocator {
    public static func resolveClaudeBinary(
        env: [String: String] = ProcessInfo.processInfo.environment,
        loginPATH: [String]? = LoginShellPathCache.shared.current,
        commandV: (String, String?, TimeInterval, FileManager) -> String? = ShellCommandLocator.commandV,
        aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String? = ShellCommandLocator
            .resolveAlias,
        fileManager: FileManager = .default,
        home: String = NSHomeDirectory()) -> String?
    {
        self.resolveBinary(
            name: "claude",
            overrideKey: "CLAUDE_CLI_PATH",
            env: env,
            loginPATH: loginPATH,
            commandV: commandV,
            aliasResolver: aliasResolver,
            wellKnownPaths: self.claudeWellKnownPaths(home: home),
            fileManager: fileManager,
            home: home)
    }

    /// Well-known installation paths for the Claude CLI binary.
    /// Covers Anthropic's native installer (`~/.local/bin`), the `claude migrate-installer`
    /// self-updating location (`~/.claude/local`), the legacy per-user installer
    /// (`~/.claude/bin`), Homebrew, and the macOS Terminal installer (cmux.app).
    static func claudeWellKnownPaths(home: String) -> [String] {
        [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.claude/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/Applications/cmux.app/Contents/Resources/bin/claude",
        ]
    }

    public static func resolveCodexBinary(
        env: [String: String] = ProcessInfo.processInfo.environment,
        loginPATH: [String]? = LoginShellPathCache.shared.current,
        commandV: (String, String?, TimeInterval, FileManager) -> String? = ShellCommandLocator.commandV,
        aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String? = ShellCommandLocator
            .resolveAlias,
        fileManager: FileManager = .default,
        home: String = NSHomeDirectory()) -> String?
    {
        self.resolveBinary(
            name: "codex",
            overrideKey: "CODEX_CLI_PATH",
            env: env,
            loginPATH: loginPATH,
            commandV: commandV,
            aliasResolver: aliasResolver,
            fileManager: fileManager,
            home: home)
    }

    public static func resolveGeminiBinary(
        env: [String: String] = ProcessInfo.processInfo.environment,
        loginPATH: [String]? = LoginShellPathCache.shared.current,
        commandV: (String, String?, TimeInterval, FileManager) -> String? = ShellCommandLocator.commandV,
        aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String? = ShellCommandLocator
            .resolveAlias,
        fileManager: FileManager = .default,
        home: String = NSHomeDirectory()) -> String?
    {
        self.resolveBinary(
            name: "gemini",
            overrideKey: "GEMINI_CLI_PATH",
            env: env,
            loginPATH: loginPATH,
            commandV: commandV,
            aliasResolver: aliasResolver,
            fileManager: fileManager,
            home: home)
    }

    public static func resolveAuggieBinary(
        env: [String: String] = ProcessInfo.processInfo.environment,
        loginPATH: [String]? = LoginShellPathCache.shared.current,
        commandV: (String, String?, TimeInterval, FileManager) -> String? = ShellCommandLocator.commandV,
        aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String? = ShellCommandLocator
            .resolveAlias,
        fileManager: FileManager = .default,
        home: String = NSHomeDirectory()) -> String?
    {
        self.resolveBinary(
            name: "auggie",
            overrideKey: "AUGGIE_CLI_PATH",
            env: env,
            loginPATH: loginPATH,
            commandV: commandV,
            aliasResolver: aliasResolver,
            fileManager: fileManager,
            home: home)
    }

    // swiftlint:disable function_parameter_count
    private static func resolveBinary(
        name: String,
        overrideKey: String,
        env: [String: String],
        loginPATH: [String]?,
        commandV: (String, String?, TimeInterval, FileManager) -> String?,
        aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String?,
        wellKnownPaths: [String] = [],
        fileManager: FileManager,
        home: String) -> String?
    {
        // swiftlint:enable function_parameter_count
        // 1) Explicit override
        if let override = env[overrideKey], fileManager.isExecutableFile(atPath: override) {
            return override
        }

        // 2) Login-shell PATH (captured once per launch)
        if let loginPATH,
           let pathHit = self.find(name, in: loginPATH, fileManager: fileManager)
        {
            return pathHit
        }

        // 3) Existing PATH
        if let existingPATH = env["PATH"],
           let pathHit = self.find(
               name,
               in: existingPATH.split(separator: ":").map(String.init),
               fileManager: fileManager)
        {
            return pathHit
        }

        // 4) Well-known installation paths (e.g. Homebrew, cmux.app bundle, ~/.claude/bin).
        // Prefer these before shell probing to avoid running interactive shell init for common installs.
        for candidate in wellKnownPaths where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }

        // 5) Interactive login shell lookup (captures nvm/fnm/mise paths from .zshrc/.bashrc)
        if let shellHit = commandV(name, env["SHELL"], 2.0, fileManager),
           fileManager.isExecutableFile(atPath: shellHit)
        {
            return shellHit
        }

        // 5b) Alias fallback (login shell); only attempt after all standard lookups fail.
        if let aliasHit = aliasResolver(name, env["SHELL"], 2.0, fileManager, home),
           fileManager.isExecutableFile(atPath: aliasHit)
        {
            return aliasHit
        }

        // 6) Minimal fallback
        let fallback = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let pathHit = self.find(name, in: fallback, fileManager: fileManager) {
            return pathHit
        }

        return nil
    }

    private static func find(_ binary: String, in paths: [String], fileManager: FileManager) -> String? {
        for path in paths where !path.isEmpty {
            let candidate = "\(path.hasSuffix("/") ? String(path.dropLast()) : path)/\(binary)"
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

public enum ShellCommandLocator {
    static func test_runShellCommand(
        shell: String,
        arguments: [String],
        timeout: TimeInterval) -> Data?
    {
        self.runShellCommand(shell: shell, arguments: arguments, timeout: timeout)
    }

    public static func commandV(
        _ tool: String,
        _ shell: String?,
        _ timeout: TimeInterval,
        _ fileManager: FileManager) -> String?
    {
        let text = self.runShellCapture(shell, timeout, "command -v \(tool)")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }

        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for line in lines.reversed() where line.hasPrefix("/") {
            let path = line
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    public static func resolveAlias(
        _ tool: String,
        _ shell: String?,
        _ timeout: TimeInterval,
        _ fileManager: FileManager,
        _ home: String) -> String?
    {
        let command = "alias \(tool) 2>/dev/null; type -a \(tool) 2>/dev/null"
        guard let text = self.runShellCapture(shell, timeout, command) else { return nil }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        if let aliasPath = self.parseAliasPath(lines, tool: tool, home: home, fileManager: fileManager) {
            return aliasPath
        }

        for line in lines {
            if let path = self.extractPathCandidate(line: line, tool: tool, home: home),
               fileManager.isExecutableFile(atPath: path)
            {
                return path
            }
        }

        return nil
    }

    /// Thread-safe buffer for collecting pipe output from a readability handler.
    private final class CapturedData: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ other: Data) {
            self.lock.lock()
            self.data.append(other)
            self.lock.unlock()
        }

        func drain() -> Data {
            self.lock.lock()
            let result = self.data
            self.lock.unlock()
            return result
        }
    }

    /// Idempotent one-shot flag — `fire()` returns true exactly once.
    /// Used to make `DispatchGroup.leave()` safe to attempt from multiple paths.
    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false

        func fire() -> Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            if self.fired { return false }
            self.fired = true
            return true
        }
    }

    // swiftlint:disable cyclomatic_complexity
    /// Runs a shell command, draining both stdout and stderr concurrently so that
    /// verbose shell init scripts (oh-my-zsh, nvm, pyenv, etc.) cannot deadlock on
    /// a full pipe buffer.  The child is launched via `posix_spawn` with
    /// `POSIX_SPAWN_SETPGROUP` so it becomes its own process-group leader *before*
    /// `exec`, which guarantees that subsequent `kill(-pgid, ...)` calls reach any
    /// background helpers spawned by shell init, on both the timeout-kill path and
    /// after normal completion.
    fileprivate static func runShellCommand(
        shell: String,
        arguments: [String],
        timeout: TimeInterval) -> Data?
    {
        // Pipes for stdout/stderr.  stdin is redirected from /dev/null in the child
        // via posix_spawn_file_actions_addopen below.
        var stdoutFds: (read: Int32, write: Int32) = (-1, -1)
        var stderrFds: (read: Int32, write: Int32) = (-1, -1)
        guard withUnsafeMutablePointer(to: &stdoutFds, {
            $0.withMemoryRebound(to: Int32.self, capacity: 2) { pipe($0) == 0 }
        }) else { return nil }
        guard withUnsafeMutablePointer(to: &stderrFds, {
            $0.withMemoryRebound(to: Int32.self, capacity: 2) { pipe($0) == 0 }
        }) else {
            close(stdoutFds.read); close(stdoutFds.write)
            return nil
        }

        // Build file actions: redirect stdin from /dev/null, dup pipe write ends to
        // fds 1 and 2, and close every pipe fd in the child.  The init pattern
        // differs between platforms because the typedef is an opaque pointer on
        // Darwin and a struct on Glibc.
        #if canImport(Darwin)
        var fileActions: posix_spawn_file_actions_t?
        #else
        var fileActions = posix_spawn_file_actions_t()
        #endif
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            close(stdoutFds.read); close(stdoutFds.write)
            close(stderrFds.read); close(stderrFds.write)
            return nil
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, stdoutFds.write, 1)
        posix_spawn_file_actions_adddup2(&fileActions, stderrFds.write, 2)
        posix_spawn_file_actions_addclose(&fileActions, stdoutFds.read)
        posix_spawn_file_actions_addclose(&fileActions, stdoutFds.write)
        posix_spawn_file_actions_addclose(&fileActions, stderrFds.read)
        posix_spawn_file_actions_addclose(&fileActions, stderrFds.write)

        // Build attributes: set the child's process group to itself in the child,
        // before exec, eliminating the race that an after-launch setpgid(2) has.
        #if canImport(Darwin)
        var attr: posix_spawnattr_t?
        #else
        var attr = posix_spawnattr_t()
        #endif
        guard posix_spawnattr_init(&attr) == 0 else {
            close(stdoutFds.read); close(stdoutFds.write)
            close(stderrFds.read); close(stderrFds.write)
            return nil
        }
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0) // 0 = child becomes its own pgid leader

        // Build argv (argv[0] is conventionally the executable path).
        var cArgs: [UnsafeMutablePointer<CChar>?] = []
        cArgs.append(strdup(shell))
        for arg in arguments {
            cArgs.append(strdup(arg))
        }
        cArgs.append(nil)
        defer {
            for p in cArgs {
                if let p {
                    free(p)
                }
            }
        }

        // Inherit the parent environment.  Build a NULL-terminated `KEY=VALUE`
        // array since `extern char **environ` isn't directly visible from Swift.
        var cEnv: [UnsafeMutablePointer<CChar>?] = []
        for (key, value) in ProcessInfo.processInfo.environment {
            cEnv.append(strdup("\(key)=\(value)"))
        }
        cEnv.append(nil)
        defer {
            for p in cEnv {
                if let p {
                    free(p)
                }
            }
        }

        var pid: pid_t = 0
        let spawnResult = shell.withCString { execPath in
            posix_spawn(&pid, execPath, &fileActions, &attr, cArgs, cEnv)
        }

        // Close the write ends in the parent so EOF will arrive on the read ends
        // once every descendant in the process group also closes them.
        close(stdoutFds.write)
        close(stderrFds.write)

        guard spawnResult == 0 else {
            close(stdoutFds.read); close(stderrFds.read)
            return nil
        }

        // POSIX_SPAWN_SETPGROUP with pgroup=0 guarantees the child's pgid == its pid.
        let pgid: pid_t = pid

        // Track EOF on each pipe so we can wait for full drain instead of sleeping.
        // The readability handler fires with empty data when every writer end is
        // closed (i.e. the child *and* any inheriting background helpers are gone).
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        drainGroup.enter()
        let stdoutDone = OnceFlag()
        let stderrDone = OnceFlag()

        let stdoutCollector = CapturedData()
        let stdoutHandle = FileHandle(fileDescriptor: stdoutFds.read, closeOnDealloc: true)
        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                if stdoutDone.fire() { drainGroup.leave() }
            } else {
                stdoutCollector.append(data)
            }
        }

        let stderrHandle = FileHandle(fileDescriptor: stderrFds.read, closeOnDealloc: true)
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                if stderrDone.fire() { drainGroup.leave() }
            }
        }

        // Reap the child on a background queue and signal a semaphore on exit.
        let exitSemaphore = DispatchSemaphore(value: 0)
        let waitPid = pid
        DispatchQueue.global(qos: .userInitiated).async {
            var status: Int32 = 0
            while waitpid(waitPid, &status, 0) == -1, errno == EINTR {
                // retry
            }
            exitSemaphore.signal()
        }

        let finishedInTime = exitSemaphore.wait(timeout: .now() + timeout) == .success

        if !finishedInTime {
            kill(-pgid, SIGTERM)
            kill(pid, SIGTERM)
            if exitSemaphore.wait(timeout: .now() + 0.4) != .success {
                kill(-pgid, SIGKILL)
                kill(pid, SIGKILL)
                _ = exitSemaphore.wait(timeout: .now() + 1.0)
            }
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            if stdoutDone.fire() { drainGroup.leave() }
            if stderrDone.fire() { drainGroup.leave() }
            return nil
        }

        // Normal completion — clean up any background children spawned by shell init.
        // Without this, helpers that inherited stdout/stderr keep the pipe write ends
        // open and we never see EOF on the read ends.
        kill(-pgid, SIGTERM)

        // Wait for both pipes to deliver EOF so no buffered bytes are lost.
        // Bounded so a stuck handler can't hang the caller indefinitely.
        if drainGroup.wait(timeout: .now() + 0.4) != .success {
            kill(-pgid, SIGKILL)
        }
        if drainGroup.wait(timeout: .now() + 0.6) != .success {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            if stdoutDone.fire() { drainGroup.leave() }
            if stderrDone.fire() { drainGroup.leave() }
        }
        return stdoutCollector.drain()
    }

    // swiftlint:enable cyclomatic_complexity

    private static func runShellCapture(_ shell: String?, _ timeout: TimeInterval, _ command: String) -> String? {
        let shellPath = (shell?.isEmpty == false) ? shell! : "/bin/zsh"
        let isCI = ["1", "true"].contains(ProcessInfo.processInfo.environment["CI"]?.lowercased())
        // Interactive login shell to pick up PATH mutations from shell init (nvm/fnm/mise).
        // CI runners can have shell init hooks that emit missing CLI errors; avoid them in CI.
        let args = isCI ? ["-c", command] : ["-l", "-i", "-c", command]
        guard let data = runShellCommand(shell: shellPath, arguments: args, timeout: timeout) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func parseAliasPath(
        _ lines: [String],
        tool: String,
        home: String,
        fileManager: FileManager) -> String?
    {
        for line in lines {
            if line.hasPrefix("alias \(tool)=") {
                let value = line.replacingOccurrences(of: "alias \(tool)=", with: "")
                if let path = self.extractAliasExpansion(value, home: home),
                   fileManager.isExecutableFile(atPath: path)
                {
                    return path
                }
            }
            if line.lowercased().contains("aliased to") {
                if let range = line.range(of: "aliased to") {
                    let value = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if let path = self.extractAliasExpansion(String(value), home: home),
                       fileManager.isExecutableFile(atPath: path)
                    {
                        return path
                    }
                }
            }
        }
        return nil
    }

    private static func extractAliasExpansion(_ raw: String, home: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'`"))
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: " ").map(String.init)
        guard let first = parts.first else { return nil }
        return self.expandPath(first, home: home)
    }

    private static func extractPathCandidate(line: String, tool: String, home: String) -> String? {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        for token in tokens {
            let candidate = self.expandPath(token, home: home)
            if candidate.hasPrefix("/"),
               URL(fileURLWithPath: candidate).lastPathComponent == tool
            {
                return candidate
            }
        }
        return nil
    }

    private static func expandPath(_ raw: String, home: String) -> String {
        if raw == "~" { return home }
        if raw.hasPrefix("~/") { return home + String(raw.dropFirst()) }
        return raw
    }
}

public enum PathBuilder {
    public static func effectivePATH(
        purposes _: Set<PathPurpose>,
        env: [String: String] = ProcessInfo.processInfo.environment,
        loginPATH: [String]? = LoginShellPathCache.shared.current,
        home _: String = NSHomeDirectory()) -> String
    {
        var parts: [String] = []

        if let loginPATH, !loginPATH.isEmpty {
            parts.append(contentsOf: loginPATH)
        }

        if let existing = env["PATH"], !existing.isEmpty {
            parts.append(contentsOf: existing.split(separator: ":").map(String.init))
        }

        if parts.isEmpty {
            parts.append(contentsOf: ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        }

        var seen = Set<String>()
        let deduped = parts.compactMap { part -> String? in
            guard !part.isEmpty else { return nil }
            if seen.insert(part).inserted {
                return part
            }
            return nil
        }

        return deduped.joined(separator: ":")
    }

    public static func debugSnapshot(
        purposes: Set<PathPurpose>,
        env: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()) -> PathDebugSnapshot
    {
        let login = LoginShellPathCache.shared.current
        let effective = self.effectivePATH(
            purposes: purposes,
            env: env,
            loginPATH: login,
            home: home)
        let codex = BinaryLocator.resolveCodexBinary(env: env, loginPATH: login, home: home)
        let claude = BinaryLocator.resolveClaudeBinary(env: env, loginPATH: login, home: home)
        let gemini = BinaryLocator.resolveGeminiBinary(env: env, loginPATH: login, home: home)
        let loginString = login?.joined(separator: ":")
        return PathDebugSnapshot(
            codexBinary: codex,
            claudeBinary: claude,
            geminiBinary: gemini,
            effectivePATH: effective,
            loginShellPATH: loginString)
    }

    public static func debugSnapshotAsync(
        purposes: Set<PathPurpose>,
        env: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()) async -> PathDebugSnapshot
    {
        await Task.detached(priority: .userInitiated) {
            self.debugSnapshot(purposes: purposes, env: env, home: home)
        }.value
    }
}

enum LoginShellPathCapturer {
    static func capture(
        shell: String? = ProcessInfo.processInfo.environment["SHELL"],
        timeout: TimeInterval = 2.0) -> [String]?
    {
        let shellPath = (shell?.isEmpty == false) ? shell! : "/bin/zsh"
        let isCI = ["1", "true"].contains(ProcessInfo.processInfo.environment["CI"]?.lowercased())
        let marker = "__CODEXBAR_PATH__"
        // Skip interactive login shells in CI to avoid noisy init hooks.
        let args = isCI
            ? ["-c", "printf '\(marker)%s\(marker)' \"$PATH\""]
            : ["-l", "-i", "-c", "printf '\(marker)%s\(marker)' \"$PATH\""]
        guard let data = ShellCommandLocator.runShellCommand(
            shell: shellPath,
            arguments: args,
            timeout: timeout),
            let raw = String(data: data, encoding: .utf8),
            !raw.isEmpty
        else { return nil }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let extracted = if let start = trimmed.range(of: marker),
                           let end = trimmed.range(of: marker, options: .backwards),
                           start.upperBound <= end.lowerBound
        {
            String(trimmed[start.upperBound..<end.lowerBound])
        } else {
            trimmed
        }

        let value = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return value.split(separator: ":").map(String.init)
    }
}

public final class LoginShellPathCache: @unchecked Sendable {
    public static let shared = LoginShellPathCache()

    private let lock = NSLock()
    private var captured: [String]?
    private var isCapturing = false
    private var callbacks: [([String]?) -> Void] = []

    public var current: [String]? {
        self.lock.lock()
        let value = self.captured
        self.lock.unlock()
        return value
    }

    public func captureOnce(
        shell: String? = ProcessInfo.processInfo.environment["SHELL"],
        timeout: TimeInterval = 2.0,
        onFinish: (([String]?) -> Void)? = nil)
    {
        self.lock.lock()
        if let captured {
            self.lock.unlock()
            onFinish?(captured)
            return
        }

        if let onFinish {
            self.callbacks.append(onFinish)
        }

        if self.isCapturing {
            self.lock.unlock()
            return
        }

        self.isCapturing = true
        self.lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = LoginShellPathCapturer.capture(shell: shell, timeout: timeout)
            guard let self else { return }

            self.lock.lock()
            self.captured = result
            self.isCapturing = false
            let callbacks = self.callbacks
            self.callbacks.removeAll()
            self.lock.unlock()

            callbacks.forEach { $0(result) }
        }
    }
}
