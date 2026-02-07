#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

actor ClaudeCLISession {
    static let shared = ClaudeCLISession()
    private static let log = CodexBarLog.logger(LogCategories.claudeCLI)

    enum SessionError: LocalizedError {
        case launchFailed(String)
        case ioFailed(String)
        case timedOut
        case processExited

        var errorDescription: String? {
            switch self {
            case let .launchFailed(msg): "Failed to launch Claude CLI session: \(msg)"
            case let .ioFailed(msg): "Claude CLI PTY I/O failed: \(msg)"
            case .timedOut: "Claude CLI session timed out."
            case .processExited: "Claude CLI session exited."
            }
        }
    }

    private var process: Process?
    private var primaryFD: Int32 = -1
    private var primaryHandle: FileHandle?
    private var secondaryHandle: FileHandle?
    private var processGroup: pid_t?
    private var binaryPath: String?
    private var startedAt: Date?

    private let promptSends: [String: String] = [
        "Do you trust the files in this folder?": "y\r",
        "Quick safety check:": "\r",
        "Yes, I trust this folder": "\r",
        "Ready to code here?": "\r",
        "Press Enter to continue": "\r",
    ]

    private struct RollingBuffer {
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
    }

    private static func normalizedNeedle(_ text: String) -> String {
        String(text.lowercased().filter { !$0.isWhitespace })
    }

    private static func commandPaletteSends(for subcommand: String) -> [String: String] {
        let normalized = subcommand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "/usage":
            // Claude's command palette can render several "Show ..." actions together; only auto-confirm the
            // usage-related actions here so we do not accidentally execute /status.
            return [
                "Show plan": "\r",
                "Show plan usage limits": "\r",
            ]
        case "/status":
            return [
                "Show Claude Code": "\r",
                "Show Claude Code status": "\r",
            ]
        default:
            return [:]
        }
    }

    func capture(
        subcommand: String,
        binary: String,
        timeout: TimeInterval,
        idleTimeout: TimeInterval? = 3.0,
        stopOnSubstrings: [String] = [],
        settleAfterStop: TimeInterval = 0.25,
        sendEnterEvery: TimeInterval? = nil) async throws -> String
    {
        try self.ensureStarted(binary: binary)
        if let startedAt {
            let sinceStart = Date().timeIntervalSince(startedAt)
            // Claude's TUI can drop early keystrokes while it's still initializing. Wait a bit longer than the
            // original 0.4s to ensure slash commands reliably open their panels.
            if sinceStart < 2.0 {
                let delay = UInt64((2.0 - sinceStart) * 1_000_000_000)
                try await Task.sleep(nanoseconds: delay)
            }
        }
        self.drainOutput()

        let trimmed = subcommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            try self.send(trimmed)
            try self.send("\r")
        }

        let stopNeedles = stopOnSubstrings.map { Self.normalizedNeedle($0) }
        var sendMap = self.promptSends
        for (needle, keys) in Self.commandPaletteSends(for: trimmed) {
            sendMap[needle] = keys
        }
        let sendNeedles = sendMap.map { (needle: Self.normalizedNeedle($0.key), keys: $0.value) }
        let cursorQuery = Data([0x1B, 0x5B, 0x36, 0x6E])
        let needleLengths =
            stopOnSubstrings.map(\.utf8.count) +
            sendMap.keys.map(\.utf8.count) +
            [cursorQuery.count]
        let maxNeedle = needleLengths.max() ?? cursorQuery.count
        var scanBuffer = RollingBuffer(maxNeedle: maxNeedle)
        var triggeredSends = Set<String>()

        var buffer = Data()
        var scanTailText = ""
        var utf8Carry = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var lastOutputAt = Date()
        var lastEnterAt = Date()
        var stoppedEarly = false
        // Only send periodic Enter when the caller explicitly asks for it (used for /usage rendering).
        // For /status, periodic input can keep producing output and prevent idle-timeout short-circuiting.
        let effectiveEnterEvery: TimeInterval? = sendEnterEvery

        while Date() < deadline {
            let newData = self.readChunk()
            if !newData.isEmpty {
                buffer.append(newData)
                lastOutputAt = Date()
                Self.appendScanText(newData: newData, scanTailText: &scanTailText, utf8Carry: &utf8Carry)
                if scanTailText.count > 8192 { scanTailText = String(scanTailText.suffix(8192)) }
            }

            let scanData = scanBuffer.append(newData)
            if !scanData.isEmpty,
               scanData.range(of: cursorQuery) != nil
            {
                try? self.send("\u{1b}[1;1R")
            }

            let normalizedScan = Self.normalizedNeedle(TextParsing.stripANSICodes(scanTailText))

            for item in sendNeedles where !triggeredSends.contains(item.needle) {
                if normalizedScan.contains(item.needle) {
                    try? self.send(item.keys)
                    triggeredSends.insert(item.needle)
                }
            }

            if stopNeedles.contains(where: normalizedScan.contains) {
                stoppedEarly = true
                break
            }

            if self.shouldStopForIdleTimeout(
                idleTimeout: idleTimeout,
                bufferIsEmpty: buffer.isEmpty,
                lastOutputAt: lastOutputAt)
            {
                stoppedEarly = true
                break
            }

            self.sendPeriodicEnterIfNeeded(every: effectiveEnterEvery, lastEnterAt: &lastEnterAt)

            if let proc = self.process, !proc.isRunning {
                throw SessionError.processExited
            }

            try await Task.sleep(nanoseconds: 60_000_000)
        }

        if stoppedEarly {
            let settle = max(0, min(settleAfterStop, deadline.timeIntervalSinceNow))
            if settle > 0 {
                let settleDeadline = Date().addingTimeInterval(settle)
                while Date() < settleDeadline {
                    let newData = self.readChunk()
                    if !newData.isEmpty { buffer.append(newData) }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }

        guard !buffer.isEmpty, let text = String(data: buffer, encoding: .utf8) else {
            throw SessionError.timedOut
        }
        return text
    }

    private static func appendScanText(newData: Data, scanTailText: inout String, utf8Carry: inout Data) {
        // PTY reads can split multibyte UTF-8 sequences. Keep a small carry buffer so prompt/stop scanning doesn't
        // drop chunks when the decode fails due to an incomplete trailing sequence.
        var combined = Data()
        combined.reserveCapacity(utf8Carry.count + newData.count)
        combined.append(utf8Carry)
        combined.append(newData)

        if let chunk = String(data: combined, encoding: .utf8) {
            scanTailText.append(chunk)
            utf8Carry.removeAll(keepingCapacity: true)
            return
        }

        for trimCount in 1...3 where combined.count > trimCount {
            let prefix = combined.dropLast(trimCount)
            if let chunk = String(data: prefix, encoding: .utf8) {
                scanTailText.append(chunk)
                utf8Carry = Data(combined.suffix(trimCount))
                return
            }
        }

        // If the data is still not UTF-8 decodable, keep only a small suffix to avoid unbounded growth.
        utf8Carry = Data(combined.suffix(12))
    }

    func reset() {
        self.cleanup()
    }

    private func ensureStarted(binary: String) throws {
        if let proc = self.process, proc.isRunning, self.binaryPath == binary {
            Self.log.debug("Claude CLI session reused")
            return
        }
        self.cleanup()

        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        var win = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primaryFD, &secondaryFD, nil, nil, &win) == 0 else {
            Self.log.warning("Claude CLI PTY openpty failed")
            throw SessionError.launchFailed("openpty failed")
        }
        _ = fcntl(primaryFD, F_SETFL, O_NONBLOCK)

        let primaryHandle = FileHandle(fileDescriptor: primaryFD, closeOnDealloc: true)
        let secondaryHandle = FileHandle(fileDescriptor: secondaryFD, closeOnDealloc: true)

        let proc = Process()
        let resolvedURL = URL(fileURLWithPath: binary)
        let disableWatchdog = ProcessInfo.processInfo.environment["CODEXBAR_DISABLE_CLAUDE_WATCHDOG"] == "1"
        if !disableWatchdog,
           resolvedURL.lastPathComponent == "claude",
           let watchdog = TTYCommandRunner.locateBundledHelper("CodexBarClaudeWatchdog")
        {
            proc.executableURL = URL(fileURLWithPath: watchdog)
            proc.arguments = ["--", binary, "--allowed-tools", ""]
        } else {
            proc.executableURL = resolvedURL
            proc.arguments = ["--allowed-tools", ""]
        }
        proc.standardInput = secondaryHandle
        proc.standardOutput = secondaryHandle
        proc.standardError = secondaryHandle

        let workingDirectory = ClaudeStatusProbe.probeWorkingDirectoryURL()
        proc.currentDirectoryURL = workingDirectory
        var env = TTYCommandRunner.enrichedEnvironment()
        env = Self.scrubbedClaudeEnvironment(from: env)
        env["PWD"] = workingDirectory.path
        proc.environment = env

        do {
            try proc.run()
            Self.log.debug(
                "Claude CLI session started",
                metadata: ["binary": URL(fileURLWithPath: binary).lastPathComponent])
        } catch {
            Self.log.warning("Claude CLI launch failed", metadata: ["error": error.localizedDescription])
            try? primaryHandle.close()
            try? secondaryHandle.close()
            throw SessionError.launchFailed(error.localizedDescription)
        }

        let pid = proc.processIdentifier
        var processGroup: pid_t?
        if setpgid(pid, pid) == 0 {
            processGroup = pid
        }

        self.process = proc
        self.primaryFD = primaryFD
        self.primaryHandle = primaryHandle
        self.secondaryHandle = secondaryHandle
        self.processGroup = processGroup
        self.binaryPath = binary
        self.startedAt = Date()
    }

    private static func scrubbedClaudeEnvironment(from base: [String: String]) -> [String: String] {
        var env = base
        let explicitKeys: [String] = [
            ClaudeOAuthCredentialsStore.environmentTokenKey,
            ClaudeOAuthCredentialsStore.environmentScopesKey,
        ]
        for key in explicitKeys {
            env.removeValue(forKey: key)
        }
        for key in env.keys where key.hasPrefix("ANTHROPIC_") {
            env.removeValue(forKey: key)
        }
        return env
    }

    private func cleanup() {
        if self.process != nil {
            Self.log.debug("Claude CLI session stopping")
        }
        if let proc = self.process, proc.isRunning {
            try? self.writeAllToPrimary(Data("/exit\r".utf8))
        }
        try? self.primaryHandle?.close()
        try? self.secondaryHandle?.close()

        if let proc = self.process, proc.isRunning {
            proc.terminate()
        }
        if let pgid = self.processGroup {
            kill(-pgid, SIGTERM)
        }
        let waitDeadline = Date().addingTimeInterval(1.0)
        if let proc = self.process {
            while proc.isRunning, Date() < waitDeadline {
                usleep(100_000)
            }
            if proc.isRunning {
                if let pgid = self.processGroup {
                    kill(-pgid, SIGKILL)
                }
                kill(proc.processIdentifier, SIGKILL)
            }
        }

        self.process = nil
        self.primaryHandle = nil
        self.secondaryHandle = nil
        self.primaryFD = -1
        self.processGroup = nil
        self.startedAt = nil
    }

    private func readChunk() -> Data {
        guard self.primaryFD >= 0 else { return Data() }
        var appended = Data()
        while true {
            var tmp = [UInt8](repeating: 0, count: 8192)
            let n = read(self.primaryFD, &tmp, tmp.count)
            if n > 0 {
                appended.append(contentsOf: tmp.prefix(n))
                continue
            }
            break
        }
        return appended
    }

    private func drainOutput() {
        _ = self.readChunk()
    }

    private func shouldStopForIdleTimeout(
        idleTimeout: TimeInterval?,
        bufferIsEmpty: Bool,
        lastOutputAt: Date) -> Bool
    {
        guard let idleTimeout, !bufferIsEmpty else { return false }
        return Date().timeIntervalSince(lastOutputAt) >= idleTimeout
    }

    private func sendPeriodicEnterIfNeeded(every: TimeInterval?, lastEnterAt: inout Date) {
        guard let every, Date().timeIntervalSince(lastEnterAt) >= every else { return }
        try? self.send("\r")
        lastEnterAt = Date()
    }

    private func send(_ text: String) throws {
        guard let data = text.data(using: .utf8) else { return }
        guard self.primaryFD >= 0 else { throw SessionError.processExited }
        try self.writeAllToPrimary(data)
    }

    private func writeAllToPrimary(_ data: Data) throws {
        guard self.primaryFD >= 0 else { throw SessionError.processExited }
        try data.withUnsafeBytes { rawBytes in
            guard let baseAddress = rawBytes.baseAddress else { return }
            var offset = 0
            var retries = 0
            while offset < rawBytes.count {
                let written = write(self.primaryFD, baseAddress.advanced(by: offset), rawBytes.count - offset)
                if written > 0 {
                    offset += written
                    retries = 0
                    continue
                }
                if written == 0 { break }

                let err = errno
                if err == EINTR || err == EAGAIN || err == EWOULDBLOCK {
                    retries += 1
                    if retries > 200 {
                        throw SessionError.ioFailed("write to PTY would block")
                    }
                    usleep(5000)
                    continue
                }
                throw SessionError.ioFailed("write to PTY failed: \(String(cString: strerror(err)))")
            }
        }
    }
}
