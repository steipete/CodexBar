#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

actor ClaudeCLISession {
    static let shared = ClaudeCLISession()

    enum SessionError: LocalizedError {
        case launchFailed(String)
        case timedOut
        case processExited

        var errorDescription: String? {
            switch self {
            case let .launchFailed(msg): "Failed to launch Claude CLI session: \(msg)"
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

    private let sendOnSubstrings: [String: String] = [
        "Do you trust the files in this folder?": "y\r",
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
            if sinceStart < 0.4 {
                let delay = UInt64((0.4 - sinceStart) * 1_000_000_000)
                try await Task.sleep(nanoseconds: delay)
            }
        }
        self.drainOutput()

        let trimmed = subcommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            try self.send(trimmed)
            try self.send("\r")
        }

        let stopNeedles = stopOnSubstrings.map { Data($0.utf8) }
        let sendNeedles = self.sendOnSubstrings.map { (needle: Data($0.key.utf8), keys: Data($0.value.utf8)) }
        let cursorQuery = Data([0x1B, 0x5B, 0x36, 0x6E])
        let needleLengths =
            stopNeedles.map(\.count) +
            sendNeedles.map(\.needle.count) +
            [cursorQuery.count]
        let maxNeedle = needleLengths.max() ?? cursorQuery.count
        var scanBuffer = RollingBuffer(maxNeedle: maxNeedle)
        var triggeredSends = Set<Data>()

        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var lastOutputAt = Date()
        var lastEnterAt = Date()
        var nextCursorCheckAt = Date(timeIntervalSince1970: 0)
        var stoppedEarly = false

        while Date() < deadline {
            let newData = self.readChunk()
            if !newData.isEmpty {
                buffer.append(newData)
                lastOutputAt = Date()
            }

            let scanData = scanBuffer.append(newData)
            if Date() >= nextCursorCheckAt,
               !scanData.isEmpty,
               scanData.range(of: cursorQuery) != nil
            {
                try? self.send("\u{1b}[1;1R")
                nextCursorCheckAt = Date().addingTimeInterval(1.0)
            }

            if !sendNeedles.isEmpty {
                for item in sendNeedles where !triggeredSends.contains(item.needle) {
                    if scanData.range(of: item.needle) != nil {
                        try? self.primaryHandle?.write(contentsOf: item.keys)
                        triggeredSends.insert(item.needle)
                    }
                }
            }

            if !stopNeedles.isEmpty, stopNeedles.contains(where: { scanData.range(of: $0) != nil }) {
                stoppedEarly = true
                break
            }

            if let idleTimeout,
               !buffer.isEmpty,
               Date().timeIntervalSince(lastOutputAt) >= idleTimeout
            {
                stoppedEarly = true
                break
            }

            if let every = sendEnterEvery, Date().timeIntervalSince(lastEnterAt) >= every {
                try? self.send("\r")
                lastEnterAt = Date()
            }

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

    func reset() {
        self.cleanup()
    }

    private func ensureStarted(binary: String) throws {
        if let proc = self.process, proc.isRunning, self.binaryPath == binary { return }
        self.cleanup()

        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        var win = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primaryFD, &secondaryFD, nil, nil, &win) == 0 else {
            throw SessionError.launchFailed("openpty failed")
        }
        _ = fcntl(primaryFD, F_SETFL, O_NONBLOCK)

        let primaryHandle = FileHandle(fileDescriptor: primaryFD, closeOnDealloc: true)
        let secondaryHandle = FileHandle(fileDescriptor: secondaryFD, closeOnDealloc: true)

        let proc = Process()
        let resolvedURL = URL(fileURLWithPath: binary)
        if resolvedURL.lastPathComponent == "claude",
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
        env["PWD"] = workingDirectory.path
        proc.environment = env

        do {
            try proc.run()
        } catch {
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

    private func cleanup() {
        if let proc = self.process, proc.isRunning, let handle = self.primaryHandle {
            try? handle.write(contentsOf: Data("/exit\n".utf8))
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
            let n = Darwin.read(self.primaryFD, &tmp, tmp.count)
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

    private func send(_ text: String) throws {
        guard let data = text.data(using: .utf8) else { return }
        guard let handle = self.primaryHandle else { throw SessionError.processExited }
        try handle.write(contentsOf: data)
    }
}
