#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

private enum TTYCommandRunnerActiveProcessRegistry {
    private static let condition = NSCondition()
    private nonisolated(unsafe) static var processes: [pid_t: ProcessInfo] = [:]
    private nonisolated(unsafe) static var isShuttingDown = false
    private nonisolated(unsafe) static var launchesInProgress = 0

    private struct ProcessInfo {
        let binary: String
        var processGroup: pid_t?
    }

    @discardableResult
    static func register(pid: pid_t, binary: String) -> Bool {
        guard pid > 0 else { return false }
        self.condition.lock()
        defer { self.condition.unlock() }
        guard !self.isShuttingDown else { return false }
        self.processes[pid] = ProcessInfo(binary: binary, processGroup: nil)
        return true
    }

    static func beginLaunch() -> Bool {
        self.condition.lock()
        defer { self.condition.unlock() }
        guard !self.isShuttingDown else { return false }
        self.launchesInProgress += 1
        return true
    }

    static func endLaunch() {
        self.condition.lock()
        self.launchesInProgress = max(0, self.launchesInProgress - 1)
        if self.launchesInProgress == 0 {
            self.condition.broadcast()
        }
        self.condition.unlock()
    }

    static func updateProcessGroup(pid: pid_t, processGroup: pid_t?) {
        guard pid > 0 else { return }
        self.condition.lock()
        guard var existing = self.processes[pid] else {
            self.condition.unlock()
            return
        }
        existing.processGroup = processGroup
        self.processes[pid] = existing
        self.condition.unlock()
    }

    static func unregister(pid: pid_t) {
        guard pid > 0 else { return }
        self.condition.lock()
        self.processes.removeValue(forKey: pid)
        self.condition.unlock()
    }

    static func drainForShutdown(
        onFenceSet: (() -> Void)? = nil)
        -> [(pid: pid_t, binary: String, processGroup: pid_t?)]
    {
        self.condition.lock()
        self.isShuttingDown = true
        onFenceSet?()
        while self.launchesInProgress > 0 {
            self.condition.wait()
        }
        let drained = self.processes.map {
            (pid: $0.key, binary: $0.value.binary, processGroup: $0.value.processGroup)
        }
        self.processes.removeAll()
        self.condition.unlock()
        return drained
    }

    static func reset() {
        self.condition.lock()
        self.processes.removeAll()
        self.isShuttingDown = false
        self.launchesInProgress = 0
        self.condition.broadcast()
        self.condition.unlock()
    }

    static func count() -> Int {
        self.condition.lock()
        let count = self.processes.count
        self.condition.unlock()
        return count
    }

    static func testTrackProcess(pid: pid_t, binary: String, processGroup: pid_t?) {
        guard pid > 0 else { return }
        self.condition.lock()
        self.processes[pid] = ProcessInfo(binary: binary, processGroup: processGroup)
        self.condition.unlock()
    }
}

enum TTYProcessTreeTerminator {
    struct ProcessIdentity: Hashable {
        let pid: pid_t
        let startToken: UInt64
    }

    static func descendantPIDs(
        of rootPID: pid_t,
        childResolver: (pid_t) -> [pid_t] = Self.currentChildPIDs(of:)) -> [pid_t]
    {
        guard rootPID > 0 else { return [] }

        var seen: Set<pid_t> = [rootPID]
        var pending = childResolver(rootPID)
        var descendants: [pid_t] = []

        while let pid = pending.popLast() {
            guard pid > 0, seen.insert(pid).inserted else { continue }
            descendants.append(pid)
            pending.append(contentsOf: childResolver(pid))
        }

        return descendants
    }

    static func currentChildPIDs(of parentPID: pid_t) -> [pid_t] {
        guard parentPID > 0 else { return [] }

        #if canImport(Darwin)
        var pids = [pid_t](repeating: 0, count: 128)
        let byteCount = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let childCount = proc_listchildpids(parentPID, &pids, byteCount)
        guard childCount > 0 else { return [] }
        return Array(pids.prefix(min(Int(childCount), pids.count))).filter { $0 > 0 }
        #else
        let taskPath = "/proc/\(parentPID)/task"
        guard let taskIDs = try? FileManager.default.contentsOfDirectory(atPath: taskPath) else { return [] }

        var children: Set<pid_t> = []
        for taskID in taskIDs {
            let childrenPath = "\(taskPath)/\(taskID)/children"
            guard let text = try? String(contentsOfFile: childrenPath, encoding: .utf8) else { continue }
            children.formUnion(text.split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) })
        }
        return children.sorted()
        #endif
    }

    static func processIdentity(for pid: pid_t) -> ProcessIdentity? {
        guard pid > 0 else { return nil }

        #if canImport(Darwin)
        var info = proc_bsdinfo()
        let size = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.stride))
        guard size == Int32(MemoryLayout<proc_bsdinfo>.stride) else { return nil }
        let startToken = UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
        return ProcessIdentity(pid: pid, startToken: startToken)
        #else
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let commandEnd = stat.lastIndex(of: ")")
        else {
            return nil
        }
        let fields = stat[stat.index(after: commandEnd)...].split(whereSeparator: \.isWhitespace)
        guard fields.count > 19, let startToken = UInt64(fields[19]) else { return nil }
        return ProcessIdentity(pid: pid, startToken: startToken)
        #endif
    }

    static func isCurrent(_ identity: ProcessIdentity) -> Bool {
        self.processIdentity(for: identity.pid) == identity
    }

    static func terminateProcessTree(
        rootPID: pid_t,
        processGroup: pid_t?,
        signal: Int32,
        knownDescendants: [pid_t] = [],
        childResolver: (pid_t) -> [pid_t] = Self.currentChildPIDs(of:),
        signalSender: (pid_t, Int32) -> Void = { kill($0, $1) })
    {
        guard rootPID > 0 else { return }

        var seen: Set<pid_t> = [rootPID]
        let descendants = knownDescendants + self.descendantPIDs(of: rootPID, childResolver: childResolver)
        for pid in descendants where pid > 0 && seen.insert(pid).inserted {
            signalSender(pid, signal)
        }
        if let processGroup {
            signalSender(-processGroup, signal)
        }
        signalSender(rootPID, signal)
    }
}

/// Executes an interactive CLI inside a pseudo-terminal and returns all captured text.
/// Keeps it minimal so we can reuse for Codex and Claude without tmux.
public struct TTYCommandRunner {
    private static let log = CodexBarLog.logger(LogCategories.ttyRunner)

    public struct Result: Sendable {
        public enum Completion: Sendable, Equatable {
            case processExited(status: Int32)
            case idleTimeout
            case outputCondition
            case deadlineExceeded
        }

        public let text: String
        public let completion: Completion
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
        public var baseEnvironment: [String: String]?
        public var initialDelay: TimeInterval = 0.4
        public var sendEnterEvery: TimeInterval?
        public var sendOnSubstrings: [String: String]
        public var stopOnURL: Bool
        public var stopOnSubstrings: [String]
        public var settleAfterStop: TimeInterval
        public var forceCodexStatusMode: Bool
        public var useClaudeProbeWorkingDirectory: Bool
        public var returnOnEmptyProcessExit: Bool
        public var cancellationCheck: @Sendable () -> Bool

        public init(
            rows: UInt16 = 50,
            cols: UInt16 = 160,
            timeout: TimeInterval = 20.0,
            idleTimeout: TimeInterval? = nil,
            workingDirectory: URL? = nil,
            extraArgs: [String] = [],
            baseEnvironment: [String: String]? = nil,
            initialDelay: TimeInterval = 0.4,
            sendEnterEvery: TimeInterval? = nil,
            sendOnSubstrings: [String: String] = [:],
            stopOnURL: Bool = false,
            stopOnSubstrings: [String] = [],
            settleAfterStop: TimeInterval = 0.25,
            forceCodexStatusMode: Bool = false,
            useClaudeProbeWorkingDirectory: Bool = false,
            returnOnEmptyProcessExit: Bool = false,
            cancellationCheck: @escaping @Sendable () -> Bool = { Task<Never, Never>.isCancelled })
        {
            self.rows = rows
            self.cols = cols
            self.timeout = timeout
            self.idleTimeout = idleTimeout
            self.workingDirectory = workingDirectory
            self.extraArgs = extraArgs
            self.baseEnvironment = baseEnvironment
            self.initialDelay = initialDelay
            self.sendEnterEvery = sendEnterEvery
            self.sendOnSubstrings = sendOnSubstrings
            self.stopOnURL = stopOnURL
            self.stopOnSubstrings = stopOnSubstrings
            self.settleAfterStop = settleAfterStop
            self.forceCodexStatusMode = forceCodexStatusMode
            self.useClaudeProbeWorkingDirectory = useClaudeProbeWorkingDirectory
            self.returnOnEmptyProcessExit = returnOnEmptyProcessExit
            self.cancellationCheck = cancellationCheck
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
        let targets = TTYCommandRunnerActiveProcessRegistry.drainForShutdown()
        guard !targets.isEmpty else { return }

        let resolvedTargets = self.resolveShutdownTargets(
            targets,
            hostProcessGroup: getpgrp(),
            groupResolver: { getpgid($0) })

        for target in resolvedTargets where target.pid > 0 {
            TTYProcessTreeTerminator.terminateProcessTree(
                rootPID: target.pid,
                processGroup: target.processGroup,
                signal: SIGTERM)
        }

        for target in resolvedTargets where target.pid > 0 {
            TTYProcessTreeTerminator.terminateProcessTree(
                rootPID: target.pid,
                processGroup: target.processGroup,
                signal: SIGKILL)
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

    struct RollingBuffer {
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

    enum DrainReadResult {
        case data(Data)
        case wouldBlock
        case closed
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

    static func drainRemainingOutput(
        until drainDeadline: Date,
        readChunk: () -> DrainReadResult,
        processChunk: (Data) -> Void,
        sleep: (UInt32) -> Void = { usleep($0) })
    {
        while Date() < drainDeadline {
            switch readChunk() {
            case let .data(newData):
                processChunk(newData)
            case .wouldBlock:
                sleep(20000)
            case .closed:
                return
            }
        }
    }

    static func drainReadResult(for data: Data, terminalRead: Int, errno err: Int32) -> DrainReadResult {
        if !data.isEmpty { return .data(data) }

        if terminalRead == 0 {
            return .closed
        }

        if terminalRead < 0 {
            if err == EAGAIN || err == EWOULDBLOCK || err == EINTR {
                return .wouldBlock
            }
            if err == EIO {
                return .closed
            }
        }

        return .closed
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

        func checkCancellation() throws {
            if options.cancellationCheck() {
                throw CancellationError()
            }
        }

        func writeAllToPrimary(_ data: Data) throws {
            try data.withUnsafeBytes { rawBytes in
                guard let baseAddress = rawBytes.baseAddress else { return }
                var offset = 0
                var retries = 0
                while offset < rawBytes.count {
                    try checkCancellation()
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

        let baseEnv = options.baseEnvironment ?? ProcessInfo.processInfo.environment
        let isClaudeCLI = Self.isClaudeBinary(requested: binary, resolved: resolved, environment: baseEnv)
        let executable: String
        let arguments: [String]
        if isClaudeCLI,
           let watchdog = Self.locateBundledHelper("CodexBarClaudeWatchdog")
        {
            executable = watchdog
            arguments = ["--", resolved] + options.extraArgs
        } else {
            executable = resolved
            arguments = options.extraArgs
        }
        // Use login-shell PATH when available, but keep the caller’s environment (HOME, LANG, etc.) so
        // the CLIs can find their auth/config files.
        var env = Self.enrichedEnvironment(baseEnv: baseEnv, home: baseEnv["HOME"] ?? NSHomeDirectory())
        let workingDirectory = options.workingDirectory
            ?? (options.useClaudeProbeWorkingDirectory && isClaudeCLI
                ? ClaudeStatusProbe.preparedProbeWorkingDirectoryURL()
                : nil)
        if let workingDirectory {
            env["PWD"] = workingDirectory.path
        }

        var cleanedUp = false
        var launchedProcess: SpawnedProcessGroup?
        /// Always tear down the PTY child (and its process group) even if we throw early
        /// while bootstrapping the CLI (e.g. when it prompts for login/telemetry).
        func cleanup() {
            guard !cleanedUp else { return }
            cleanedUp = true

            if let launchedProcess, launchedProcess.isRunning {
                Self.log.debug("PTY stopping", metadata: ["binary": binaryName])
                let exitData = Data("/exit\n".utf8)
                try? writeAllToPrimary(exitData)
            }

            try? secondaryHandle.close()

            guard let launchedProcess else {
                try? primaryHandle.close()
                return
            }
            launchedProcess.terminateSynchronously()
            try? primaryHandle.close()
            TTYCommandRunnerActiveProcessRegistry.unregister(pid: launchedProcess.pid)
        }

        guard TTYCommandRunnerActiveProcessRegistry.beginLaunch() else {
            cleanup()
            throw Error.launchFailed("App shutdown in progress")
        }
        var launchReservationHeld = true
        defer {
            if launchReservationHeld {
                TTYCommandRunnerActiveProcessRegistry.endLaunch()
            }
        }

        // Ensure the PTY process is always torn down, even when we throw early (e.g. login prompt).
        defer { cleanup() }

        let process: SpawnedProcessGroup
        do {
            try checkCancellation()
            process = try SpawnedProcessGroup.launchPTY(
                binary: executable,
                arguments: arguments,
                environment: env,
                workingDirectory: workingDirectory,
                fileDescriptors: (primary: primaryFD, secondary: secondaryFD))
            launchedProcess = process
            try? secondaryHandle.close()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.log.warning(
                "PTY launch failed",
                metadata: ["binary": binaryName, "error": error.localizedDescription])
            throw Error.launchFailed(error.localizedDescription)
        }

        let pid = process.pid
        guard TTYCommandRunnerActiveProcessRegistry.register(pid: pid, binary: binaryName) else {
            Self.log.debug("PTY launch blocked by shutdown fence", metadata: ["binary": binaryName])
            throw Error.launchFailed("App shutdown in progress")
        }
        TTYCommandRunnerActiveProcessRegistry.updateProcessGroup(pid: pid, processGroup: process.processGroup)
        TTYCommandRunnerActiveProcessRegistry.endLaunch()
        launchReservationHeld = false
        Self.log.debug("PTY launched", metadata: ["binary": binaryName])

        func send(_ text: String) throws {
            guard let data = text.data(using: .utf8) else { return }
            try writeAllToPrimary(data)
        }

        let deadline = Date().addingTimeInterval(options.timeout)
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        let isCodex = (binaryName == "codex") || options.forceCodexStatusMode
        let isCodexStatus = isCodex && trimmed == "/status"

        var buffer = Data()
        func readChunkResult() -> (data: Data, terminalRead: Int, errno: Int32) {
            var appended = Data()
            var terminalRead = 0
            var terminalErrno: Int32 = 0
            while true {
                var tmp = [UInt8](repeating: 0, count: 8192)
                errno = 0
                let n = read(primaryFD, &tmp, tmp.count)
                if n > 0 {
                    let slice = tmp.prefix(n)
                    buffer.append(contentsOf: slice)
                    appended.append(contentsOf: slice)
                    continue
                }
                terminalRead = Int(n)
                terminalErrno = errno
                break
            }
            return (appended, terminalRead, terminalErrno)
        }

        func readChunk() -> Data {
            readChunkResult().data
        }

        func readDrainChunk() -> DrainReadResult {
            let result = readChunkResult()
            return Self.drainReadResult(for: result.data, terminalRead: result.terminalRead, errno: result.errno)
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
        try checkCancellation()

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
            var terminatedForIdle = false

            func processNonCodexChunk(_ newData: Data, allowSends: Bool, allowStop: Bool) -> Bool {
                guard !newData.isEmpty else { return false }

                lastOutputAt = Date()
                if let chunkText = String(bytes: newData, encoding: .utf8) {
                    recentText += chunkText
                    if recentText.count > 8192 {
                        recentText.removeFirst(recentText.count - 8192)
                    }
                }

                let scanData = scanBuffer.append(newData)
                if Date() >= nextCursorCheckAt,
                   scanData.range(of: cursorQuery) != nil
                {
                    try? send("\u{1b}[1;1R")
                    nextCursorCheckAt = Date().addingTimeInterval(1.0)
                }

                if allowSends, !sendNeedles.isEmpty {
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
                    if !urlSeen {
                        urlSeen = true
                        onURLDetected?()
                    }
                    if allowStop, options.stopOnURL {
                        return true
                    }
                }

                if allowStop, !stopNeedles.isEmpty, stopNeedles.contains(where: { scanData.range(of: $0) != nil }) {
                    return true
                }

                return false
            }

            while Date() < deadline {
                try checkCancellation()
                let readResult = readDrainChunk()
                let newData = switch readResult {
                case let .data(data):
                    data
                case .wouldBlock, .closed:
                    Data()
                }
                if processNonCodexChunk(newData, allowSends: true, allowStop: true) {
                    stoppedEarly = true
                    break
                }
                if let idleTimeout = options.idleTimeout,
                   !buffer.isEmpty,
                   Date().timeIntervalSince(lastOutputAt) >= idleTimeout
                {
                    stoppedEarly = true
                    terminatedForIdle = true
                    break
                }

                if !urlSeen, let every = options.sendEnterEvery, Date().timeIntervalSince(lastEnter) >= every {
                    try? send("\r")
                    lastEnter = Date()
                }

                if case .closed = readResult, !process.isRunning { break }
                if !process.isRunning { break }
                usleep(60000)
            }

            if stoppedEarly {
                let settle = max(0, min(options.settleAfterStop, deadline.timeIntervalSinceNow))
                if settle > 0 {
                    let settleDeadline = Date().addingTimeInterval(settle)
                    while Date() < settleDeadline {
                        try checkCancellation()
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
            } else if !process.isRunning {
                // PTY-backed scripts can exit before their final echo becomes readable on the parent side.
                // Give the kernel a brief non-blocking drain window so we don't lose the last line of output.
                let drainFor = max(0, min(0.2, deadline.timeIntervalSinceNow))
                if drainFor > 0 {
                    Self.drainRemainingOutput(
                        until: Date().addingTimeInterval(drainFor),
                        readChunk: readDrainChunk,
                        processChunk: { _ = processNonCodexChunk($0, allowSends: false, allowStop: false) })
                }
            }

            let text = String(data: buffer, encoding: .utf8) ?? ""
            let completion: Result.Completion = if !process.isRunning {
                .processExited(status: process.finishSynchronously() ?? 1)
            } else if terminatedForIdle {
                .idleTimeout
            } else if stoppedEarly {
                .outputCondition
            } else {
                .deadlineExceeded
            }
            if text.isEmpty {
                guard options.returnOnEmptyProcessExit,
                      case .processExited = completion
                else {
                    throw Error.timedOut
                }
            }
            return Result(text: text, completion: completion)
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
            try checkCancellation()
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
                try checkCancellation()
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

        let completion: Result.Completion = if !process.isRunning {
            .processExited(status: process.finishSynchronously() ?? 1)
        } else if sawCodexStatus {
            .outputCondition
        } else {
            .deadlineExceeded
        }
        return Result(text: text, completion: completion)
    }

    // swiftlint:enable function_body_length
}

extension TTYCommandRunner {
    public static func which(_ tool: String) -> String? {
        if tool == "codex", let located = BinaryLocator.resolveCodexBinary() { return located }
        if tool == "claude", let located = BinaryLocator.resolveClaudeBinary() { return located }
        return self.runWhich(tool)
    }

    private static func isClaudeBinary(requested: String, resolved: String, environment: [String: String]) -> Bool {
        let requestedName = URL(fileURLWithPath: requested).lastPathComponent
        let resolvedName = URL(fileURLWithPath: resolved).lastPathComponent
        if requested == "claude" || requestedName == "claude" || resolvedName == "claude" {
            return true
        }

        guard let override = environment["CLAUDE_CLI_PATH"], !override.isEmpty else { return false }
        let normalizedOverride = self.normalizedExecutablePath(override)
        return self.normalizedExecutablePath(resolved) == normalizedOverride
            || self.normalizedExecutablePath(requested) == normalizedOverride
    }

    private static func normalizedExecutablePath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(expanded, &buffer) != nil {
            return buffer.withUnsafeBufferPointer { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return expanded }
                return String(cString: baseAddress)
            }
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private static func runWhich(_ tool: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [tool]
        var env = ProcessInfo.processInfo.environment
        let loginPATH = LoginShellPathCache.shared.currentOrCapture()
        env["PATH"] = PathBuilder.effectivePATH(
            purposes: [.tty, .nodeTooling],
            env: env,
            loginPATH: loginPATH)
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
}

extension TTYCommandRunner {
    @discardableResult
    static func registerActiveProcessForAppShutdown(pid: pid_t, binary: String) -> Bool {
        TTYCommandRunnerActiveProcessRegistry.register(pid: pid, binary: binary)
    }

    static func beginActiveProcessLaunchForAppShutdown() -> Bool {
        TTYCommandRunnerActiveProcessRegistry.beginLaunch()
    }

    static func endActiveProcessLaunchForAppShutdown() {
        TTYCommandRunnerActiveProcessRegistry.endLaunch()
    }

    static func updateActiveProcessGroupForAppShutdown(pid: pid_t, processGroup: pid_t?) {
        TTYCommandRunnerActiveProcessRegistry.updateProcessGroup(pid: pid, processGroup: processGroup)
    }

    static func unregisterActiveProcessForAppShutdown(pid: pid_t) {
        TTYCommandRunnerActiveProcessRegistry.unregister(pid: pid)
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

    @discardableResult
    static func _test_registerTrackedProcess(pid: pid_t, binary: String) -> Bool {
        TTYCommandRunnerActiveProcessRegistry.register(pid: pid, binary: binary)
    }

    static func _test_trackedProcessCount() -> Int {
        TTYCommandRunnerActiveProcessRegistry.count()
    }

    static func _test_beginTrackedProcessLaunch() -> Bool {
        TTYCommandRunnerActiveProcessRegistry.beginLaunch()
    }

    static func _test_endTrackedProcessLaunch() {
        TTYCommandRunnerActiveProcessRegistry.endLaunch()
    }

    static func _test_drainTrackedProcessesForShutdown(
        onFenceSet: (() -> Void)? = nil)
        -> [(pid: pid_t, binary: String, processGroup: pid_t?)]
    {
        TTYCommandRunnerActiveProcessRegistry.drainForShutdown(onFenceSet: onFenceSet)
    }

    static func _test_resolveShutdownTargets(
        _ targets: [(pid: pid_t, binary: String, processGroup: pid_t?)],
        hostProcessGroup: pid_t,
        groupResolver: (pid_t) -> pid_t) -> [(pid: pid_t, binary: String, processGroup: pid_t?)]
    {
        self.resolveShutdownTargets(targets, hostProcessGroup: hostProcessGroup, groupResolver: groupResolver)
    }
}
