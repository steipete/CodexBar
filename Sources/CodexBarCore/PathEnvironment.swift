import Foundation

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
            fileManager: fileManager,
            home: home)
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

    // swiftlint:disable function_parameter_count
    private static func resolveBinary(
        name: String,
        overrideKey: String,
        env: [String: String],
        loginPATH: [String]?,
        commandV: (String, String?, TimeInterval, FileManager) -> String?,
        aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String?,
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

        // 4) Interactive login shell lookup (captures nvm/fnm/mise paths from .zshrc/.bashrc)
        if let shellHit = commandV(name, env["SHELL"], 2.0, fileManager),
           fileManager.isExecutableFile(atPath: shellHit)
        {
            return shellHit
        }

        // 4b) Alias fallback (login shell); only attempt after all standard lookups fail.
        if let aliasHit = aliasResolver(name, env["SHELL"], 2.0, fileManager, home),
           fileManager.isExecutableFile(atPath: aliasHit)
        {
            return aliasHit
        }

        // 5) Minimal fallback
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

    private static func runShellCapture(_ shell: String?, _ timeout: TimeInterval, _ command: String) -> String? {
        let shellPath = (shell?.isEmpty == false) ? shell! : "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        // Interactive login shell to pick up PATH mutations from shell init (nvm/fnm/mise).
        process.arguments = ["-l", "-i", "-c", command]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
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
}

enum LoginShellPathCapturer {
    static func capture(
        shell: String? = ProcessInfo.processInfo.environment["SHELL"],
        timeout: TimeInterval = 2.0) -> [String]?
    {
        let shellPath = (shell?.isEmpty == false) ? shell! : "/bin/zsh"
        let marker = "__CODEXBAR_PATH__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-l", "-i", "-c", "printf '\(marker)%s\(marker)' \"$PATH\""]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8),
              !raw.isEmpty else { return nil }

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
