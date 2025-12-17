import Darwin
import Foundation

/// Executes an interactive CLI inside a pseudo-terminal and returns all captured text.
/// Keeps it minimal so we can reuse for Codex and Claude without tmux.
public struct TTYCommandRunner {
    public struct Result: Sendable {
        public let text: String
    }

    public struct Options: Sendable {
        public var rows: UInt16 = 50
        public var cols: UInt16 = 160
        public var timeout: TimeInterval = 20.0
        public var workingDirectory: URL?
        public var extraArgs: [String] = []
        public var sendEnterEvery: TimeInterval?
        public var sendOnSubstrings: [String: String]
        public var stopOnURL: Bool
        public var stopOnSubstrings: [String]
        public var settleAfterStop: TimeInterval

        public init(
            rows: UInt16 = 50,
            cols: UInt16 = 160,
            timeout: TimeInterval = 20.0,
            workingDirectory: URL? = nil,
            extraArgs: [String] = [],
            sendEnterEvery: TimeInterval? = nil,
            sendOnSubstrings: [String: String] = [:],
            stopOnURL: Bool = false,
            stopOnSubstrings: [String] = [],
            settleAfterStop: TimeInterval = 0.25)
        {
            self.rows = rows
            self.cols = cols
            self.timeout = timeout
            self.workingDirectory = workingDirectory
            self.extraArgs = extraArgs
            self.sendEnterEvery = sendEnterEvery
            self.sendOnSubstrings = sendOnSubstrings
            self.stopOnURL = stopOnURL
            self.stopOnSubstrings = stopOnSubstrings
            self.settleAfterStop = settleAfterStop
        }
    }

    public enum Error: Swift.Error, LocalizedError, Sendable {
        case binaryNotFound(String)
        case launchFailed(String)
        case timedOut

        public var errorDescription: String? {
            switch self {
            case let .binaryNotFound(bin):
                "Missing CLI '\(bin)'. Install it (e.g. npm i -g @openai/codex) or add it to PATH."
            case let .launchFailed(msg): "Failed to launch process: \(msg)"
            case .timedOut: "PTY command timed out."
            }
        }
    }

    public init() {}

    // swiftlint:disable function_body_length
    // swiftlint:disable:next cyclomatic_complexity
    public func run(
        binary: String,
        send script: String,
        options: Options = Options(),
        onURLDetected: (@Sendable () -> Void)? = nil) throws -> Result
    {
        let resolved: String
        if FileManager.default.isExecutableFile(atPath: binary) {
            resolved = binary
        } else if let hit = Self.which(binary) {
            resolved = hit
        } else {
            throw Error.binaryNotFound(binary)
        }

        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        var win = winsize(ws_row: options.rows, ws_col: options.cols, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primaryFD, &secondaryFD, nil, nil, &win) == 0 else {
            throw Error.launchFailed("openpty failed")
        }
        // Make primary side non-blocking so read loops don't hang when no data is available.
        _ = fcntl(primaryFD, F_SETFL, O_NONBLOCK)

        let primaryHandle = FileHandle(fileDescriptor: primaryFD, closeOnDealloc: true)
        let secondaryHandle = FileHandle(fileDescriptor: secondaryFD, closeOnDealloc: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: resolved)
        proc.arguments = options.extraArgs
        proc.standardInput = secondaryHandle
        proc.standardOutput = secondaryHandle
        proc.standardError = secondaryHandle
        // Mirror RPC PATH seeding so CLIs installed via npm/nvm/fnm/bun still launch in hardened builds,
        // but keep the caller’s environment (HOME, LANG, BUN_INSTALL, etc.) so the CLIs can find their
        // auth/config files.
        var env = Self.enrichedEnvironment()
        if let workingDirectory = options.workingDirectory {
            proc.currentDirectoryURL = workingDirectory
            env["PWD"] = workingDirectory.path
        }
        proc.environment = env

        var cleanedUp = false
        var didLaunch = false
        var processGroup: pid_t?
        // Always tear down the PTY child (and its process group) even if we throw early
        // while bootstrapping the CLI (e.g. when it prompts for login/telemetry).
        func cleanup() {
            guard !cleanedUp else { return }
            cleanedUp = true

            if didLaunch, proc.isRunning {
                let exitData = Data("/exit\n".utf8)
                try? primaryHandle.write(contentsOf: exitData)
            }

            try? primaryHandle.close()
            try? secondaryHandle.close()

            guard didLaunch else { return }

            if proc.isRunning {
                proc.terminate()
            }
            if let pgid = processGroup {
                kill(-pgid, SIGTERM)
            }
            let waitDeadline = Date().addingTimeInterval(2.0)
            while proc.isRunning, Date() < waitDeadline {
                usleep(100_000)
            }
            if proc.isRunning {
                if let pgid = processGroup {
                    kill(-pgid, SIGKILL)
                }
                kill(proc.processIdentifier, SIGKILL)
            }
            if didLaunch {
                proc.waitUntilExit()
            }
        }

        // Ensure the PTY process is always torn down, even when we throw early (e.g. login prompt).
        defer { cleanup() }

        try proc.run()
        didLaunch = true

        // Isolate the child into its own process group so descendant helpers can be
        // terminated together. If this fails (e.g. process already exec'ed), we
        // continue and fall back to single-PID termination.
        let pid = proc.processIdentifier
        if setpgid(pid, pid) == 0 {
            processGroup = pid
        }

        func send(_ text: String) throws {
            guard let data = text.data(using: .utf8) else { return }
            try primaryHandle.write(contentsOf: data)
        }

        let deadline = Date().addingTimeInterval(options.timeout)
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        let isCodex = (binary == "codex")
        let isCodexStatus = isCodex && trimmed == "/status"

        var buffer = Data()
        func readChunk() {
            while true {
                var tmp = [UInt8](repeating: 0, count: 8192)
                let n = Darwin.read(primaryFD, &tmp, tmp.count)
                if n > 0 {
                    buffer.append(contentsOf: tmp.prefix(n))
                    continue
                }
                break
            }
        }

        func firstLink(in data: Data) -> String? {
            guard let s = String(data: data, encoding: .utf8) else { return nil }
            let pattern = #"https?://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            guard let match = regex.firstMatch(in: s, range: range), let r = Range(match.range, in: s) else {
                return nil
            }
            var url = String(s[r])
            while let last = url.unicodeScalars.last,
                  CharacterSet(charactersIn: ".,;:)]}>\"'").contains(last)
            {
                url.unicodeScalars.removeLast()
            }
            return url
        }

        func containsCodexStatus() -> Bool {
            let markers = [
                "Credits:",
                "5h limit",
                "5-hour limit",
                "Weekly limit",
            ].map { Data($0.utf8) }
            return markers.contains { buffer.contains($0) }
        }

        func respondIfCursorQuerySeen() {
            let query = Data([0x1B, 0x5B, 0x36, 0x6E])
            if buffer.contains(query) { try? send("\u{1b}[1;1R") }
        }

        func containsCodexUpdatePrompt() -> Bool {
            let needles = ["Update available!", "Run bun install -g @openai/codex", "0.60.1 ->"]
            let lower = String(data: buffer, encoding: .utf8)?.lowercased() ?? ""
            return needles.contains { lower.contains($0.lowercased()) }
        }

        usleep(400_000) // small boot grace

        // Generic path for non-Codex (e.g. Claude /login)
        if !isCodex {
            if !trimmed.isEmpty {
                try send(trimmed)
                try send("\r")
            }

            let stopNeedles = options.stopOnSubstrings.map { Data($0.utf8) }
            let sendNeedles = options.sendOnSubstrings.map { (needle: Data($0.key.utf8), keys: Data($0.value.utf8)) }
            let urlNeedles = [Data("https://".utf8), Data("http://".utf8)]
            var lastEnter = Date()
            var stoppedEarly = false
            var urlSeen = false
            var triggeredSends = Set<Data>()

            while Date() < deadline {
                readChunk()
                respondIfCursorQuerySeen()

                if !sendNeedles.isEmpty {
                    for item in sendNeedles where !triggeredSends.contains(item.needle) {
                        if buffer.range(of: item.needle) != nil {
                            try? primaryHandle.write(contentsOf: item.keys)
                            triggeredSends.insert(item.needle)
                        }
                    }
                }

                if urlNeedles.contains(where: { buffer.range(of: $0) != nil }) {
                    urlSeen = true
                    if urlSeen {
                        onURLDetected?()
                    }
                    if options.stopOnURL {
                        stoppedEarly = true
                        break
                    }
                }
                if !stopNeedles.isEmpty, stopNeedles.contains(where: { buffer.range(of: $0) != nil }) {
                    stoppedEarly = true
                    break
                }

                if !urlSeen, let every = options.sendEnterEvery, Date().timeIntervalSince(lastEnter) >= every {
                    try? send("\r")
                    lastEnter = Date()
                }

                if !proc.isRunning { break }
                usleep(60000)
            }

            if stoppedEarly {
                let settle = max(0, min(options.settleAfterStop, deadline.timeIntervalSinceNow))
                if settle > 0 {
                    let settleDeadline = Date().addingTimeInterval(settle)
                    while Date() < settleDeadline {
                        readChunk()
                        respondIfCursorQuerySeen()
                        usleep(50000)
                    }
                }
            }

            let text = String(data: buffer, encoding: .utf8) ?? ""
            guard !text.isEmpty else { throw Error.timedOut }
            return Result(text: text)
        }

        // Codex-specific behavior (/status and update handling)
        let delayInitialSend = isCodexStatus
        if !delayInitialSend {
            try send(script)
            try send("\r")
            usleep(150_000)
            try send("\r")
            try send("\u{1b}")
        }

        var skippedCodexUpdate = false
        var sentScript = !delayInitialSend
        var updateSkipAttempts = 0
        var lastEnter = Date(timeIntervalSince1970: 0)
        var scriptSentAt: Date? = sentScript ? Date() : nil
        var resendStatusRetries = 0
        var enterRetries = 0
        var sawCodexStatus = false

        while Date() < deadline {
            readChunk()
            respondIfCursorQuerySeen()
            if !skippedCodexUpdate, containsCodexUpdatePrompt() {
                // Prompt shows options: 1) Update now, 2) Skip, 3) Skip until next version.
                // Users report one Down + Enter is enough; follow with an extra Enter for safety, then re-run
                // /status.
                try? send("\u{1b}[B") // highlight option 2 (Skip)
                usleep(120_000)
                try? send("\r")
                usleep(150_000)
                try? send("\r") // if still focused on prompt, confirm again
                try? send("/status")
                try? send("\r")
                updateSkipAttempts += 1
                if updateSkipAttempts >= 1 {
                    skippedCodexUpdate = true
                    sentScript = false // re-send /status after dismissing
                    scriptSentAt = nil
                    buffer.removeAll()
                }
                usleep(300_000)
            }
            if !sentScript, !containsCodexUpdatePrompt() || skippedCodexUpdate {
                try? send(script)
                try? send("\r")
                sentScript = true
                scriptSentAt = Date()
                lastEnter = Date()
                usleep(200_000)
                continue
            }
            if sentScript, !containsCodexStatus() {
                if Date().timeIntervalSince(lastEnter) >= 1.2, enterRetries < 6 {
                    try? send("\r")
                    enterRetries += 1
                    lastEnter = Date()
                    usleep(120_000)
                    continue
                }
                if let sentAt = scriptSentAt,
                   Date().timeIntervalSince(sentAt) >= 3.0,
                   resendStatusRetries < 2
                {
                    try? send("/status")
                    try? send("\r")
                    resendStatusRetries += 1
                    buffer.removeAll()
                    scriptSentAt = Date()
                    lastEnter = Date()
                    usleep(220_000)
                    continue
                }
            }
            if containsCodexStatus() {
                sawCodexStatus = true
                break
            }
            usleep(120_000)
        }

        if sawCodexStatus {
            let settleDeadline = Date().addingTimeInterval(2.0)
            while Date() < settleDeadline {
                readChunk()
                respondIfCursorQuerySeen()
                usleep(100_000)
            }
        }

        guard let text = String(data: buffer, encoding: .utf8), !text.isEmpty else {
            throw Error.timedOut
        }

        return Result(text: text)
    }

    // swiftlint:enable function_body_length

    public static func which(_ tool: String) -> String? {
        if tool == "codex", let located = BinaryLocator.resolveCodexBinary() { return located }
        if tool == "claude", let located = BinaryLocator.resolveClaudeBinary() { return located }
        // First try system PATH
        if let path = runWhich(tool) { return path }
        // Fallback to common locations (Homebrew, local bins)
        let home = NSHomeDirectory()
        var candidates = [
            "/opt/homebrew/bin/\(tool)",
            "/usr/local/bin/\(tool)",
            "\(home)/.local/bin/\(tool)",
            "\(home)/bin/\(tool)",
        ]
        if tool == "claude" {
            candidates.append(contentsOf: [
                "\(home)/.claude/local/\(tool)",
                "\(home)/.claude/bin/\(tool)",
            ])
        }
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return nil
    }

    private static func runWhich(_ tool: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [tool]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try? proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty else { return nil }
        return path
    }

    /// Expands PATH with the same defaults we use for Codex RPC, so TTY probes can find CLIs installed via Homebrew,
    /// bun, nvm, fnm, or npm.
    public static func enrichedPath() -> String {
        PathBuilder.effectivePATH(
            purposes: [.tty, .nodeTooling],
            env: ProcessInfo.processInfo.environment)
    }

    static func enrichedEnvironment(
        baseEnv: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()) -> [String: String]
    {
        var env = baseEnv
        env["PATH"] = PathBuilder.effectivePATH(
            purposes: [.tty, .nodeTooling],
            env: baseEnv,
            home: home)
        if env["HOME"]?.isEmpty ?? true {
            env["HOME"] = home
        }
        if env["TERM"]?.isEmpty ?? true {
            env["TERM"] = "xterm-256color"
        }
        if env["COLORTERM"]?.isEmpty ?? true {
            env["COLORTERM"] = "truecolor"
        }
        if env["LANG"]?.isEmpty ?? true {
            env["LANG"] = "en_US.UTF-8"
        }
        if env["CI"] == nil {
            env["CI"] = "0"
        }
        return env
    }
}
