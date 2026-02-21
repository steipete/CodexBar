#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

private enum TTYCommandRunnerActiveProcessRegistry {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var processes: [pid_t: ProcessInfo] = [:]

    private struct ProcessInfo {
        let binary: String
        var processGroup: pid_t?
    }

    static func register(pid: pid_t, binary: String) {
        guard pid > 0 else { return }
        self.lock.lock()
        self.processes[pid] = ProcessInfo(binary: binary, processGroup: nil)
        self.lock.unlock()
    }

    static func updateProcessGroup(pid: pid_t, processGroup: pid_t?) {
        guard pid > 0 else { return }
        self.lock.lock()
        guard var existing = self.processes[pid] else {
            self.lock.unlock()
            return
        }
        existing.processGroup = processGroup
        self.processes[pid] = existing
        self.lock.unlock()
    }

    static func unregister(pid: pid_t) {
        guard pid > 0 else { return }
        self.lock.lock()
        self.processes.removeValue(forKey: pid)
        self.lock.unlock()
    }

    static func drain() -> [(pid: pid_t, binary: String, processGroup: pid_t?)] {
        self.lock.lock()
        let drained = self.processes.map {
            (pid: $0.key, binary: $0.value.binary, processGroup: $0.value.processGroup)
        }
        self.processes.removeAll()
        self.lock.unlock()
        return drained
    }

    static func reset() {
        self.lock.lock()
        self.processes.removeAll()
        self.lock.unlock()
    }

    static func count() -> Int {
        self.lock.lock()
        let count = self.processes.count
        self.lock.unlock()
        return count
    }

    static func testTrackProcess(pid: pid_t, binary: String, processGroup: pid_t?) {
        guard pid > 0 else { return }
        self.lock.lock()
        self.processes[pid] = ProcessInfo(binary: binary, processGroup: processGroup)
        self.lock.unlock()
    }
}

/// Executes an interactive CLI inside a pseudo-terminal and returns all captured text.
/// Keeps it minimal so we can reuse for Codex and Claude without tmux.
public struct TTYCommandRunner {
    private static let log = CodexBarLog.logger(LogCategories.ttyRunner)

    public struct Result: Sendable {
        public let text: String
    }

    public struct Options: Sendable {
        public var rows: UInt16 = 50
        public var cols: UInt16 = 160
        public var timeout: TimeInterval = 20.0
        /// Stop early once output has been idle for this long (only for non-Codex flows).
        /// Useful for interactive TUIs that render once and then wait for input indefinitely.
        public var idleTimeout: TimeInterval?
        public var workingDirectory: URL?
        public var extraArgs: [String] = []
        public var initialDelay: TimeInterval = 0.4
        public var sendEnterEvery: TimeInterval?
        public var sendOnSubstrings: [String: String]
        public var stopOnURL: Bool
        public var stopOnSubstrings: [String]
        public var settleAfterStop: TimeInterval

        public init(
            rows: UInt16 = 50,
            cols: UInt16 = 160,
            timeout: TimeInterval = 20.0,
            idleTimeout: TimeInterval? = nil,
            workingDirectory: URL? = nil,
            extraArgs: [String] = [],
            initialDelay: TimeInterval = 0.4,
            sendEnterEvery: TimeInterval? = nil,
            sendOnSubstrings: [String: String] = [:],
            stopOnURL: Bool = false,
            stopOnSubstrings: [String] = [],
            settleAfterStop: TimeInterval = 0.25)
        {
            self.rows = rows
            self.cols = cols
            self.timeout = timeout
            self.idleTimeout = idleTimeout
            self.workingDirectory = workingDirectory
            self.extraArgs = extraArgs
            self.initialDelay = initialDelay
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

    public static func terminateActiveProcessesForAppShutdown() {
        let targets = TTYCommandRunnerActiveProcessRegistry.drain()
        guard !targets.isEmpty else { return }

        let resolvedTargets = self.resolveShutdownTargets(
            targets,
            hostProcessGroup: getpgrp(),
            groupResolver: { getpgid($0) })

        for target in resolvedTargets where target.pid > 0 {
            if let pgid = target.processGroup {
                kill(-pgid, SIGTERM)
            }
            kill(target.pid, SIGTERM)
        }

        for target in resolvedTargets where target.pid > 0 {
            if let pgid = target.processGroup {
                kill(-pgid, SIGKILL)
            }
            kill(target.pid, SIGKILL)
        }
    }

    private static func resolveShutdownTargets(
        _ targets: [(pid: pid_t, binary: String, processGroup: pid_t?)],
        hostProcessGroup: pid_t,
        groupResolver: (pid_t) -> pid_t) -> [(pid: pid_t, binary: String, processGroup: pid_t?)]
    {
        var resolvedTargets: [(pid: pid_t, binary: String, processGroup: pid_t?)] = []
        resolvedTargets.reserveCapacity(targets.count)

        for target in targets {
            var resolvedGroup = target.processGroup
            if resolvedGroup == nil {
                let pgid = groupResolver(target.pid)
                if pgid > 0, pgid != hostProcessGroup {
                    resolvedGroup = pgid
                }
            } else if resolvedGroup == hostProcessGroup {
                resolvedGroup = nil
            }

            resolvedTargets.append((pid: target.pid, binary: target.binary, processGroup: resolvedGroup))
        }
        return resolvedTargets
    }

    struct RollingBuffer: Sendable {
        private let maxNeedle: Int
        private var tail = Data()

        init(maxNeedle: Int) {
            self.maxNeedle = max(0, maxNeedle)
        }

        mutating func append(_ data: Data) -> Data {
            guard !data.isEmpty else { return Data() }

            var combined = Data()
            combined.reserveCapacity(self.tail.count + data.count)
            combined.append(self.tail)
            combined.append(data)

            if self.maxNeedle > 1 {
                if combined.count >= self.maxNeedle - 1 {
                    self.tail = combined.suffix(self.maxNeedle - 1)
                } else {
                    self.tail = combined
                }
            } else {
                self.tail.removeAll(keepingCapacity: true)
            }

            return combined
        }

        mutating func reset() {
            self.tail.removeAll(keepingCapacity: true)
        }
    }

    static func lowercasedASCII(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        var out = Data(count: data.count)
        out.withUnsafeMutableBytes { dest in
            data.withUnsafeBytes { source in
                let src = source.bindMemory(to: UInt8.self)
                let dst = dest.bindMemory(to: UInt8.self)
                for idx in 0..<src.count {
                    var byte = src[idx]
                    if byte >= 65, byte <= 90 { byte += 32 }
                    dst[idx] = byte
                }
            }
        }
        return out
    }

    static func locateBundledHelper(_ name: String) -> String? {
        let fm = FileManager.default

        func isExecutable(_ path: String) -> Bool {
            fm.isExecutableFile(atPath: path)
        }

        if let override = ProcessInfo.processInfo.environment["CODEXBAR_HELPER_\(name.uppercased())"],
           isExecutable(override)
        {
            return override
        }

        func candidate(inAppBundleURL appURL: URL) -> String? {
            let path = appURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
                .path
            return isExecutable(path) ? path : nil
        }

        let mainURL = Bundle.main.bundleURL
        if mainURL.pathExtension == "app", let found = candidate(inAppBundleURL: mainURL) { return found }

        if let argv0 = CommandLine.arguments.first {
            var url = URL(fileURLWithPath: argv0)
            if !argv0.hasPrefix("/") {
                url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(argv0)
            }
            var probe = url
            for _ in 0..<6 {
                let parent = probe.deletingLastPathComponent()
                if parent.pathExtension == "app", let found = candidate(inAppBundleURL: parent) { return found }
                if parent.path == probe.path { break }
                probe = parent
            }
        }

        return nil
    }

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
            Self.log.warning("PTY binary not found", metadata: ["binary": binary])
            throw Error.binaryNotFound(binary)
        }

        let binaryName = URL(fileURLWithPath: resolved).lastPathComponent
        Self.log.debug(
            "PTY start",
            metadata: [
                "binary": binaryName,
                "timeout": "\(options.timeout)",
                "rows": "\(options.rows)",
                "cols": "\(options.cols)",
                "args": "\(options.extraArgs.count)",
            ])

        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        var win = winsize(ws_row: options.rows, ws_col: options.cols, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primaryFD, &secondaryFD, nil, nil, &win) == 0 else {
            Self.log.warning("PTY openpty failed", metadata: ["binary": binaryName])
            throw Error.launchFailed("openpty failed")
        }
        // Make primary side non-blocking so read loops don't hang when no data is available.
        _ = fcntl(primaryFD, F_SETFL, O_NONBLOCK)

        let primaryHandle = FileHandle(fileDescriptor: primaryFD, closeOnDealloc: true)
        let secondaryHandle = FileHandle(fileDescriptor: secondaryFD, closeOnDealloc: true)

        func writeAllToPrimary(_ data: Data) throws {
            try data.withUnsafeBytes { rawBytes in
                guard let baseAddress = rawBytes.baseAddress else { return }
                var offset = 0
                var retries = 0
                while offset < rawBytes.count {
                    let written = write(primaryFD, baseAddress.advanced(by: offset), rawBytes.count - offset)
                    if written > 0 {
                        offset += written
                        retries = 0
                        continue
                    }
                    if written == 0 { break }

                    let err = errno
                    if err == EAGAIN || err == EWOULDBLOCK {
                        retries += 1
                        if retries > 200 {
                            throw Error.launchFailed("write to PTY would block")
                        }
                        usleep(5000)
                        continue
                    }
                    throw Error.launchFailed("write to PTY failed: \(String(cString: strerror(err)))")
                }
            }
        }

        let proc = Process()
        let resolvedURL = URL(fileURLWithPath: resolved)
        if resolvedURL.lastPathComponent == "claude",
           let watchdog = Self.locateBundledHelper("CodexBarClaudeWatchdog")
        {
            proc.executableURL = URL(fileURLWithPath: watchdog)
            proc.arguments = ["--", resolved] + options.extraArgs
        } else {
            proc.executableURL = resolvedURL
            proc.arguments = options.extraArgs
        }
        proc.standardInput = secondaryHandle
        proc.standardOutput = secondaryHandle
        proc.standardError = secondaryHandle
        // Use login-shell PATH when available, but keep the caller’s environment (HOME, LANG, etc.) so
        // the CLIs can find their auth/config files.
        var env = Self.enrichedEnvironment()
        if let workingDirectory = options.workingDirectory {
            proc.currentDirectoryURL = workingDirectory
            env["PWD"] = workingDirectory.path
        }
        proc.environment = env

        var cleanedUp = false
        var didLaunch = false
        var processGroup: pid_t?
        /// Always tear down the PTY child (and its process group) even if we throw early
        /// while bootstrapping the CLI (e.g. when it prompts for login/telemetry).
        func cleanup() {
            guard !cleanedUp else { return }
            cleanedUp = true
            if didLaunch {
                TTYCommandRunnerActiveProcessRegistry.unregister(pid: proc.processIdentifier)
            }

            if didLaunch, proc.isRunning {
                Self.log.debug("PTY stopping", metadata: ["binary": binaryName])
                let exitData = Data("/exit\n".utf8)
                try? writeAllToPrimary(exitData)
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

        do {
            try proc.run()
            didLaunch = true
            TTYCommandRunnerActiveProcessRegistry.register(pid: proc.processIdentifier, binary: binaryName)
            Self.log.debug("PTY launched", metadata: ["binary": binaryName])
        } catch {
            Self.log.warning(
                "PTY launch failed",
                metadata: ["binary": binaryName, "error": error.localizedDescription])
            throw Error.launchFailed(error.localizedDescription)
        }

        // Isolate the child into its own process group so descendant helpers can be
        // terminated together. If this fails (e.g. process already exec'ed), we
        // continue and fall back to single-PID termination.
        let pid = proc.processIdentifier
        if setpgid(pid, pid) == 0 {
            processGroup = pid
            TTYCommandRunnerActiveProcessRegistry.updateProcessGroup(pid: pid, processGroup: pid)
        }

        func send(_ text: String) throws {
            guard let data = text.data(using: .utf8) else { return }
            try writeAllToPrimary(data)
        }

        let deadline = Date().addingTimeInterval(options.timeout)
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        let isCodex = (binaryName == "codex")
        let isCodexStatus = isCodex && trimmed == "/status"

        var buffer = Data()
        func readChunk() -> Data {
            var appended = Data()
            while true {
                var tmp = [UInt8](repeating: 0, count: 8192)
                let n = read(primaryFD, &tmp, tmp.count)
                if n > 0 {
                    let slice = tmp.prefix(n)
                    buffer.append(contentsOf: slice)
                    appended.append(contentsOf: slice)
                    continue
                }
                break
            }
            return appended
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

        let cursorQuery = Data([0x1B, 0x5B, 0x36, 0x6E])

        usleep(UInt32(options.initialDelay * 1_000_000))

        // Generic path for non-Codex (e.g. Claude /login)
        if !isCodex {
            if !trimmed.isEmpty {
                try send(trimmed)
                try send("\r")
            }

            let stopNeedles = options.stopOnSubstrings.map { Data($0.utf8) }
            let sendNeedles = options.sendOnSubstrings.map { (
                needle: Data($0.key.utf8),
                needleString: $0.key,
                keys: Data($0.value.utf8)) }
            let urlNeedles = [Data("https://".utf8), Data("http://".utf8)]
            let needleLengths =
                stopNeedles.map(\.count) +
                sendNeedles.map(\.needle.count) +
                urlNeedles.map(\.count) +
                [cursorQuery.count]
            let maxNeedle = needleLengths.max() ?? cursorQuery.count
            var scanBuffer = RollingBuffer(maxNeedle: maxNeedle)
            var nextCursorCheckAt = Date(timeIntervalSince1970: 0)
            var lastEnter = Date()
            var stoppedEarly = false
            var urlSeen = false
            var triggeredSends = Set<Data>()
            var recentText = ""
            var lastOutputAt = Date()

            while Date() < deadline {
                let newData = readChunk()
                if !newData.isEmpty {
                    lastOutputAt = Date()
                    if let chunkText = String(bytes: newData, encoding: .utf8) {
                        recentText += chunkText
                        if recentText.count > 8192 {
                            recentText.removeFirst(recentText.count - 8192)
                        }
                    }
                }
                let scanData = scanBuffer.append(newData)
                if Date() >= nextCursorCheckAt,
                   !scanData.isEmpty,
                   scanData.range(of: cursorQuery) != nil
                {
                    try? send("\u{1b}[1;1R")
                    nextCursorCheckAt = Date().addingTimeInterval(1.0)
                }

                if !sendNeedles.isEmpty {
                    let recentTextCollapsed = recentText.replacingOccurrences(of: "\r", with: "")
                    for item in sendNeedles where !triggeredSends.contains(item.needle) {
                        let matched = scanData.range(of: item.needle) != nil ||
                            recentText.contains(item.needleString) ||
                            recentTextCollapsed.contains(item.needleString)
                        if matched {
                            if let keysString = String(data: item.keys, encoding: .utf8) {
                                try? send(keysString)
                            } else {
                                try? writeAllToPrimary(item.keys)
                            }
                            triggeredSends.insert(item.needle)
                        }
                    }
                }

                if urlNeedles.contains(where: { scanData.range(of: $0) != nil }) {
                    urlSeen = true
                    if urlSeen {
                        onURLDetected?()
                    }
                    if options.stopOnURL {
                        stoppedEarly = true
                        break
                    }
                }
                if !stopNeedles.isEmpty, stopNeedles.contains(where: { scanData.range(of: $0) != nil }) {
                    stoppedEarly = true
                    break
                }
                if let idleTimeout = options.idleTimeout,
                   !buffer.isEmpty,
                   Date().timeIntervalSince(lastOutputAt) >= idleTimeout
                {
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
                        let newData = readChunk()
                        let scanData = scanBuffer.append(newData)
                        if Date() >= nextCursorCheckAt,
                           !scanData.isEmpty,
                           scanData.range(of: cursorQuery) != nil
                        {
                            try? send("\u{1b}[1;1R")
                            nextCursorCheckAt = Date().addingTimeInterval(1.0)
                        }
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
        var sawCodexUpdatePrompt = false
        let statusMarkers = [
            "Credits:",
            "5h limit",
            "5-hour limit",
            "Weekly limit",
        ].map { Data($0.utf8) }
        let updateNeedles = ["Update available!", "Run bun install -g @openai/codex", "0.60.1 ->"]
        let updateNeedlesLower = updateNeedles.map { Data($0.lowercased().utf8) }
        let statusNeedleLengths = statusMarkers.map(\.count)
        let updateNeedleLengths = updateNeedlesLower.map(\.count)
        let statusMaxNeedle = ([cursorQuery.count] + statusNeedleLengths).max() ?? cursorQuery.count
        let updateMaxNeedle = updateNeedleLengths.max() ?? 0
        var statusScanBuffer = RollingBuffer(maxNeedle: statusMaxNeedle)
        var updateScanBuffer = RollingBuffer(maxNeedle: updateMaxNeedle)
        var nextCursorCheckAt = Date(timeIntervalSince1970: 0)

        while Date() < deadline {
            let newData = readChunk()
            let scanData = statusScanBuffer.append(newData)
            if Date() >= nextCursorCheckAt,
               !scanData.isEmpty,
               scanData.range(of: cursorQuery) != nil
            {
                try? send("\u{1b}[1;1R")
                nextCursorCheckAt = Date().addingTimeInterval(1.0)
            }
            if !scanData.isEmpty, !sawCodexStatus {
                if statusMarkers.contains(where: { scanData.range(of: $0) != nil }) {
                    sawCodexStatus = true
                }
            }

            if !skippedCodexUpdate, !sawCodexUpdatePrompt, !newData.isEmpty {
                let lowerData = Self.lowercasedASCII(newData)
                let lowerScan = updateScanBuffer.append(lowerData)
                if !sawCodexUpdatePrompt {
                    if updateNeedlesLower.contains(where: { lowerScan.range(of: $0) != nil }) {
                        sawCodexUpdatePrompt = true
                    }
                }
            }

            if !skippedCodexUpdate, sawCodexUpdatePrompt {
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
                    statusScanBuffer.reset()
                    updateScanBuffer.reset()
                    sawCodexStatus = false
                }
                usleep(300_000)
            }
            if !sentScript, !sawCodexUpdatePrompt || skippedCodexUpdate {
                try? send(script)
                try? send("\r")
                sentScript = true
                scriptSentAt = Date()
                lastEnter = Date()
                usleep(200_000)
                continue
            }
            if sentScript, !sawCodexStatus {
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
                    statusScanBuffer.reset()
                    updateScanBuffer.reset()
                    sawCodexStatus = false
                    scriptSentAt = Date()
                    lastEnter = Date()
                    usleep(220_000)
                    continue
                }
            }
            if sawCodexStatus { break }
            usleep(120_000)
        }

        if sawCodexStatus {
            let settleDeadline = Date().addingTimeInterval(2.0)
            while Date() < settleDeadline {
                let newData = readChunk()
                let scanData = statusScanBuffer.append(newData)
                if Date() >= nextCursorCheckAt,
                   !scanData.isEmpty,
                   scanData.range(of: cursorQuery) != nil
                {
                    try? send("\u{1b}[1;1R")
                    nextCursorCheckAt = Date().addingTimeInterval(1.0)
                }
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
        return self.runWhich(tool)
    }

    private static func runWhich(_ tool: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [tool]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = PathBuilder.effectivePATH(purposes: [.tty, .nodeTooling], env: env)
        proc.environment = env
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

    /// Uses login-shell PATH when available so TTY probes match the user's shell configuration.
    public static func enrichedPath() -> String {
        PathBuilder.effectivePATH(
            purposes: [.tty, .nodeTooling],
            env: ProcessInfo.processInfo.environment)
    }

    static func enrichedEnvironment(
        baseEnv: [String: String] = ProcessInfo.processInfo.environment,
        loginPATH: [String]? = LoginShellPathCache.shared.current,
        home: String = NSHomeDirectory()) -> [String: String]
    {
        var env = baseEnv
        env["PATH"] = PathBuilder.effectivePATH(
            purposes: [.tty, .nodeTooling],
            env: baseEnv,
            loginPATH: loginPATH,
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

    static func _test_resetTrackedProcesses() {
        TTYCommandRunnerActiveProcessRegistry.reset()
    }

    static func _test_trackProcess(pid: pid_t, binary: String, processGroup: pid_t?) {
        TTYCommandRunnerActiveProcessRegistry.testTrackProcess(
            pid: pid,
            binary: binary,
            processGroup: processGroup)
    }

    static func _test_trackedProcessCount() -> Int {
        TTYCommandRunnerActiveProcessRegistry.count()
    }

    static func _test_resolveShutdownTargets(
        _ targets: [(pid: pid_t, binary: String, processGroup: pid_t?)],
        hostProcessGroup: pid_t,
        groupResolver: (pid_t) -> pid_t) -> [(pid: pid_t, binary: String, processGroup: pid_t?)]
    {
        self.resolveShutdownTargets(targets, hostProcessGroup: hostProcessGroup, groupResolver: groupResolver)
    }
}
