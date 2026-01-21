#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

actor CodexCLISession {
    static let shared = CodexCLISession()

    enum SessionError: LocalizedError {
        case launchFailed(String)
        case timedOut
        case processExited

        var errorDescription: String? {
            switch self {
            case let .launchFailed(msg): "Failed to launch Codex CLI session: \(msg)"
            case .timedOut: "Codex CLI session timed out."
            case .processExited: "Codex CLI session exited."
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
    private var ptyRows: UInt16 = 0
    private var ptyCols: UInt16 = 0

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

    // swiftlint:disable cyclomatic_complexity
    func captureStatus(binary: String, timeout: TimeInterval, rows: UInt16, cols: UInt16) async throws -> String {
        try self.ensureStarted(binary: binary, rows: rows, cols: cols)
        if let startedAt {
            let sinceStart = Date().timeIntervalSince(startedAt)
            if sinceStart < 0.4 {
                let delay = UInt64((0.4 - sinceStart) * 1_000_000_000)
                try await Task.sleep(nanoseconds: delay)
            }
        }
        self.drainOutput()

        let script = "/status"
        let cursorQuery = Data([0x1B, 0x5B, 0x36, 0x6E])
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

        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var nextCursorCheckAt = Date(timeIntervalSince1970: 0)

        var skippedCodexUpdate = false
        var sentScript = false
        var updateSkipAttempts = 0
        var lastEnter = Date(timeIntervalSince1970: 0)
        var scriptSentAt: Date?
        var resendStatusRetries = 0
        var enterRetries = 0
        var sawCodexStatus = false
        var sawCodexUpdatePrompt = false

        while Date() < deadline {
            let newData = self.readChunk()
            if !newData.isEmpty {
                buffer.append(newData)
            }
            let scanData = statusScanBuffer.append(newData)
            if Date() >= nextCursorCheckAt,
               !scanData.isEmpty,
               scanData.range(of: cursorQuery) != nil
            {
                try? self.send("\u{1b}[1;1R")
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
                if updateNeedlesLower.contains(where: { lowerScan.range(of: $0) != nil }) {
                    sawCodexUpdatePrompt = true
                }
            }

            if !skippedCodexUpdate, sawCodexUpdatePrompt {
                try? self.send("\u{1b}[B")
                try await Task.sleep(nanoseconds: 120_000_000)
                try? self.send("\r")
                try await Task.sleep(nanoseconds: 150_000_000)
                try? self.send("\r")
                try? self.send(script)
                try? self.send("\r")
                updateSkipAttempts += 1
                if updateSkipAttempts >= 1 {
                    skippedCodexUpdate = true
                    sentScript = false
                    scriptSentAt = nil
                    buffer.removeAll()
                    statusScanBuffer.reset()
                    updateScanBuffer.reset()
                    sawCodexStatus = false
                }
                try await Task.sleep(nanoseconds: 300_000_000)
            }

            if !sentScript, !sawCodexUpdatePrompt || skippedCodexUpdate {
                try? self.send(script)
                try? self.send("\r")
                sentScript = true
                scriptSentAt = Date()
                lastEnter = Date()
                try await Task.sleep(nanoseconds: 200_000_000)
                continue
            }
            if sentScript, !sawCodexStatus {
                if Date().timeIntervalSince(lastEnter) >= 1.2, enterRetries < 6 {
                    try? self.send("\r")
                    enterRetries += 1
                    lastEnter = Date()
                    try await Task.sleep(nanoseconds: 120_000_000)
                    continue
                }
                if let sentAt = scriptSentAt,
                   Date().timeIntervalSince(sentAt) >= 3.0,
                   resendStatusRetries < 2
                {
                    try? self.send(script)
                    try? self.send("\r")
                    resendStatusRetries += 1
                    buffer.removeAll()
                    statusScanBuffer.reset()
                    updateScanBuffer.reset()
                    sawCodexStatus = false
                    scriptSentAt = Date()
                    lastEnter = Date()
                    try await Task.sleep(nanoseconds: 220_000_000)
                    continue
                }
            }
            if sawCodexStatus { break }
            if let proc = self.process, !proc.isRunning {
                throw SessionError.processExited
            }
            try await Task.sleep(nanoseconds: 120_000_000)
        }

        if sawCodexStatus {
            let settleDeadline = Date().addingTimeInterval(2.0)
            while Date() < settleDeadline {
                let newData = self.readChunk()
                if !newData.isEmpty {
                    buffer.append(newData)
                }
                let scanData = statusScanBuffer.append(newData)
                if Date() >= nextCursorCheckAt,
                   !scanData.isEmpty,
                   scanData.range(of: cursorQuery) != nil
                {
                    try? self.send("\u{1b}[1;1R")
                    nextCursorCheckAt = Date().addingTimeInterval(1.0)
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        guard !buffer.isEmpty, let text = String(data: buffer, encoding: .utf8) else {
            throw SessionError.timedOut
        }
        return text
    }

    // swiftlint:enable cyclomatic_complexity

    func reset() {
        self.cleanup()
    }

    private func ensureStarted(binary: String, rows: UInt16, cols: UInt16) throws {
        if let proc = self.process,
           proc.isRunning,
           self.binaryPath == binary,
           self.ptyRows == rows,
           self.ptyCols == cols
        {
            return
        }
        self.cleanup()

        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        var win = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primaryFD, &secondaryFD, nil, nil, &win) == 0 else {
            throw SessionError.launchFailed("openpty failed")
        }
        _ = fcntl(primaryFD, F_SETFL, O_NONBLOCK)

        let primaryHandle = FileHandle(fileDescriptor: primaryFD, closeOnDealloc: true)
        let secondaryHandle = FileHandle(fileDescriptor: secondaryFD, closeOnDealloc: true)

        let proc = Process()
        let resolvedURL = URL(fileURLWithPath: binary)
        proc.executableURL = resolvedURL
        proc.arguments = ["-s", "read-only", "-a", "untrusted"]
        proc.standardInput = secondaryHandle
        proc.standardOutput = secondaryHandle
        proc.standardError = secondaryHandle

        let env = TTYCommandRunner.enrichedEnvironment()
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
        self.ptyRows = rows
        self.ptyCols = cols
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
        self.binaryPath = nil
        self.startedAt = nil
        self.ptyRows = 0
        self.ptyCols = 0
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

    private func send(_ text: String) throws {
        guard let data = text.data(using: .utf8) else { return }
        guard let handle = self.primaryHandle else { throw SessionError.processExited }
        try handle.write(contentsOf: data)
    }
}
