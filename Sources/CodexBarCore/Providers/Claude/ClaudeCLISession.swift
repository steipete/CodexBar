#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

actor ClaudeCLISession {
    static let shared = ClaudeCLISession()
    private static let log = CodexBarLog.logger(LogCategories.provider(.claude, scope: "cli"))
    private static let fallbackProbeSessionID = UUID()
    #if DEBUG
    @TaskLocal private static var sessionOverrideForTesting: ClaudeCLISession?

    static var current: ClaudeCLISession {
        self.sessionOverrideForTesting ?? self.shared
    }

    static func withIsolatedSessionForTesting<T>(operation: () async throws -> T) async rethrows -> T {
        let session = ClaudeCLISession()
        defer { Task { await session.reset() } }
        return try await self.$sessionOverrideForTesting.withValue(session) {
            try await operation()
        }
    }
    #else
    static var current: ClaudeCLISession {
        self.shared
    }
    #endif

    enum SessionError: LocalizedError {
        case launchFailed(String)
        case ioFailed(String)
        case timedOut
        case processExited
        case outputTooLarge

        var errorDescription: String? {
            switch self {
            case let .launchFailed(msg): "Failed to launch Claude CLI session: \(msg)"
            case let .ioFailed(msg): "Claude CLI PTY I/O failed: \(msg)"
            case .timedOut: "Claude CLI session timed out."
            case .processExited: "Claude CLI session exited."
            case .outputTooLarge: "Claude CLI session produced more output than CodexBar can safely process."
            }
        }
    }

    private struct SessionIdentity: Equatable {
        let binaryPath: String
        let accountScope: String?
        @ProcessEnvironment private(set) var environment: [String: String]
    }

    private struct CaptureRequest {
        let subcommand: String
        let binary: String
        let accountScope: String?
        let timeout: TimeInterval
        @ProcessEnvironment private(set) var environment: [String: String]
        let idleTimeout: TimeInterval?
        let stopOnSubstrings: [String]
        let stopWhenNormalized: (@Sendable (String) -> Bool)?
        let settleAfterStop: TimeInterval
        let sendEnterEvery: TimeInterval?
    }

    private var process: Process?
    private var primaryFD: Int32 = -1
    private var primaryHandle: FileHandle?
    private var secondaryHandle: FileHandle?
    private var processGroup: pid_t?
    private var sessionIdentity: SessionIdentity?
    private var startedAt: Date?
    private var launchedInProbeDirectory = false
    private let operationGate = AsyncOperationGate()
    private let workingDirectory: URL?

    init(workingDirectory: URL? = nil) {
        self.workingDirectory = workingDirectory
    }

    /// Workspace permission prompts use the directory-constrained handler below, never a generic Enter response.
    private let continuePrompts = ["Press Enter to continue"]

    private static func normalizedNeedle(_ text: String) -> String {
        String(text.lowercased().filter { !$0.isWhitespace })
    }

    private static func commandPalettePrompt(for subcommand: String) -> String? {
        // Claude can render several "Show ..." actions together; confirm only the requested panel's action.
        switch subcommand.lowercased() {
        case "/usage": "Show plan"
        case "/status": "Show Claude Code"
        default: nil
        }
    }

    func capture(
        subcommand: String,
        binary: String,
        accountScope: String? = nil,
        timeout: TimeInterval,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        idleTimeout: TimeInterval? = 3.0,
        stopOnSubstrings: [String] = [],
        stopWhenNormalized: (@Sendable (String) -> Bool)? = nil,
        settleAfterStop: TimeInterval = 0.25,
        sendEnterEvery: TimeInterval? = nil) async throws -> String
    {
        let operationID = UUID()
        let acquired = await withTaskCancellationHandler {
            await self.operationGate.acquire(id: operationID, rejectIfCancelled: true)
        } onCancel: {
            Task { await self.operationGate.cancel(id: operationID) }
        }
        guard acquired else { throw CancellationError() }

        do {
            try Task.checkCancellation()
            let output = try await self.captureExclusive(request: CaptureRequest(
                subcommand: subcommand,
                binary: binary,
                accountScope: accountScope,
                timeout: timeout,
                environment: environment,
                idleTimeout: idleTimeout,
                stopOnSubstrings: stopOnSubstrings,
                stopWhenNormalized: stopWhenNormalized,
                settleAfterStop: settleAfterStop,
                sendEnterEvery: sendEnterEvery))
            await self.operationGate.release(id: operationID)
            return output
        } catch {
            await self.operationGate.release(id: operationID)
            throw error
        }
    }

    private func captureExclusive(request: CaptureRequest) async throws -> String {
        if try self.ensureStarted(request: request) {
            // Dismiss /usage or /status before typing; keep Escape separate from the next command's input.
            try self.send("\u{1b}")
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        var readyAt = (self.startedAt ?? Date()).addingTimeInterval(2)
        var commandSent = false
        let trimmed = request.subcommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let stopNeedles = request.stopOnSubstrings.map(Self.normalizedNeedle)
        let sendNeedles = (self.continuePrompts + [Self.commandPalettePrompt(for: trimmed)].compactMap(\.self))
            .map(Self.normalizedNeedle)
        var triggeredSends = Set<String>()
        let cursorQuery = Data([0x1B, 0x5B, 0x36, 0x6E])
        var scanBuffer = StreamScanBuffer(maxNeedle: cursorQuery.count)
        var buffer = BoundedOutputBuffer()
        func appendOutput(_ data: Data) throws {
            guard buffer.append(data) else {
                self.cleanup()
                throw SessionError.outputTooLarge
            }
        }
        var deadline = max(Date(), readyAt).addingTimeInterval(request.timeout)
        var lastOutputAt = Date()
        var lastEnterAt = Date()
        var uncheckedFrame = false
        var trustPending = false
        var trustKeysLeft = 4
        var stoppedEarly = false
        while Date() < deadline {
            let newData = self.readChunk()
            if !newData.isEmpty {
                try appendOutput(newData)
                lastOutputAt = Date()
                uncheckedFrame = true
                if scanBuffer.append(newData).range(of: cursorQuery) != nil {
                    try? self.send("\u{1b}[1;1R")
                }
            }
            // Startup and command captures share one prompt path. Decode the retained bytes together so split UTF-8
            // and cursor redraws cannot turn the default No selection into an accidental confirmation.
            if uncheckedFrame, Date().timeIntervalSince(lastOutputAt) >= 0.2 || self.process?.isRunning == false,
               let text = String(data: buffer.data, encoding: .utf8)
            {
                uncheckedFrame = false
                let screen = ClaudeCLIScreen.render(text)
                let normalized = Self.normalizedNeedle(screen)
                let trustKeys = Self.workspaceTrustKeys(onScreen: screen, acceptsTrust: self.launchedInProbeDirectory)
                trustPending = trustKeys != nil || normalized.contains("quicksafetycheck:") ||
                    normalized.contains("doyoutrustthefilesinthisfolder?") ||
                    normalized.contains("readytocodehere?")
                if trustPending {
                    if self.process?.isRunning == true, trustKeysLeft > 0, let trustKeys {
                        try self.send(trustKeys)
                        trustKeysLeft = trustKeys == "\u{1b}" ? 0 : trustKeysLeft - 1
                        readyAt = Date().addingTimeInterval(2)
                    }
                } else {
                    if commandSent, stopNeedles.contains(where: normalized.contains)
                        || (request.stopWhenNormalized?(normalized) == true)
                    {
                        stoppedEarly = true
                        break
                    }
                    for needle in sendNeedles where !triggeredSends.contains(needle) {
                        if self.process?.isRunning == true, normalized.contains(needle) {
                            try? self.send("\r")
                            triggeredSends.insert(needle)
                            if !commandSent { readyAt = Date().addingTimeInterval(2) }
                        }
                    }
                }
            }
            if !commandSent, !trustPending, !uncheckedFrame, Date() >= readyAt {
                buffer.removeAll(keepingCapacity: true)
                if !trimmed.isEmpty { try self.send(trimmed + "\r") }
                commandSent = true
                lastOutputAt = Date()
                lastEnterAt = Date()
                deadline = Date().addingTimeInterval(request.timeout)
            }
            if commandSent, !trustPending, !uncheckedFrame {
                if request.idleTimeout.map({ !buffer.isEmpty && Date().timeIntervalSince(lastOutputAt) >= $0 }) == true
                {
                    stoppedEarly = true
                    break
                }
                self.sendPeriodicEnterIfNeeded(every: request.sendEnterEvery, lastEnterAt: &lastEnterAt)
            }
            if let proc = self.process, !proc.isRunning {
                Self.log.warning(
                    "Claude CLI session exited during capture",
                    metadata: ["status": "\(proc.terminationStatus)"])
                throw SessionError.processExited
            }
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        if stoppedEarly {
            let settleDeadline = min(deadline, Date().addingTimeInterval(max(0, request.settleAfterStop)))
            while Date() < settleDeadline {
                try appendOutput(self.readChunk())
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        guard commandSent, !trustPending, !buffer.isEmpty,
              let text = String(data: buffer.data, encoding: .utf8) else { throw SessionError.timedOut }
        return text
    }

    /// Returns the key for the workspace trust dialog on screen, or nil when it is not shown. Without `acceptsTrust`,
    /// Escape cancels the dialog whichever option is selected. With it, an arrow moves the `❯` marker toward "Yes, I
    /// trust this folder" and Enter follows once the marker is on it; nil while no marker is found, so Enter can never
    /// confirm a different option.
    static func workspaceTrustKeys(onScreen screen: String, acceptsTrust: Bool) -> String? {
        let normalized = Self.normalizedNeedle(screen)
        let lines = screen.components(separatedBy: "\n")
        let option = "yes,itrustthisfolder"
        guard let optionRow = lines.firstIndex(where: { Self.normalizedNeedle($0).contains(option) }) else {
            if normalized.contains("quicksafetycheck:") { return acceptsTrust ? nil : "\u{1b}" }
            if normalized.contains("doyoutrustthefilesinthisfolder?") { return acceptsTrust ? "y\r" : "\u{1b}" }
            if normalized.contains("readytocodehere?") { return acceptsTrust ? "\r" : "\u{1b}" }
            return nil
        }
        guard acceptsTrust else { return "\u{1b}" }
        // Only accept a marker from the same option list; blank lines separate it from the dialog's other text.
        let isBlank = { (row: Int) in lines[row].allSatisfy(\.isWhitespace) }
        var firstRow = optionRow
        while firstRow > lines.startIndex, !isBlank(firstRow - 1) {
            firstRow -= 1
        }
        var lastRow = optionRow
        while lastRow < lines.endIndex - 1, !isBlank(lastRow + 1) {
            lastRow += 1
        }
        guard let markerRow = (firstRow...lastRow).first(where: { lines[$0].contains("❯") }) else { return nil }
        if markerRow == optionRow { return "\r" }
        return markerRow < optionRow ? "\u{1b}[B" : "\u{1b}[A"
    }

    func reset() async {
        let operationID = UUID()
        _ = await self.operationGate.acquire(id: operationID, rejectIfCancelled: false)
        self.cleanup()
        await self.operationGate.release(id: operationID)
    }

    /// Returns whether the existing process was reused.
    private func ensureStarted(request: CaptureRequest) throws -> Bool {
        let sessionIdentity = SessionIdentity(
            binaryPath: request.binary,
            accountScope: request.accountScope,
            environment: Self.launchEnvironment(baseEnv: request.environment))
        if let proc = self.process, proc.isRunning, self.sessionIdentity == sessionIdentity {
            Self.log.debug("Claude CLI session reused")
            return true
        }
        self.cleanup()
        let workingDirectory = try self.workingDirectory ?? Self.isolatedProbeWorkingDirectoryURL()

        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        var win = winsize(
            ws_row: UInt16(ClaudeCLIScreen.rows),
            ws_col: UInt16(ClaudeCLIScreen.columns),
            ws_xpixel: 0,
            ws_ypixel: 0)
        guard openpty(&primaryFD, &secondaryFD, nil, nil, &win) == 0 else {
            Self.log.warning("Claude CLI PTY openpty failed")
            throw SessionError.launchFailed("openpty failed")
        }
        _ = fcntl(primaryFD, F_SETFL, O_NONBLOCK)

        let primaryHandle = FileHandle(fileDescriptor: primaryFD, closeOnDealloc: true)
        let secondaryHandle = FileHandle(fileDescriptor: secondaryFD, closeOnDealloc: true)

        let proc = Process()
        let resolvedURL = URL(fileURLWithPath: request.binary)
        // A crashed probe can leave a JSONL behind. Claude treats `--session-id` as creation-only when that local
        // transcript exists, so clear the probe-owned artifact before reusing the account-side identifier.
        ClaudeProbeSessionArtifactCleaner.cleanupProbeSessionArtifacts(
            probeDirectory: workingDirectory,
            environment: sessionIdentity.environment)
        let sessionID = Self.loadOrCreateProbeSessionID(in: workingDirectory)
        let claudeArguments = Self.launchArguments(sessionID: sessionID)
        let disableWatchdog = sessionIdentity.environment["CODEXBAR_DISABLE_CLAUDE_WATCHDOG"] == "1"
        if !disableWatchdog,
           resolvedURL.lastPathComponent == "claude",
           let watchdog = TTYCommandRunner.locateBundledHelper("CodexBarClaudeWatchdog")
        {
            proc.executableURL = URL(fileURLWithPath: watchdog)
            proc.arguments = ["--", request.binary] + claudeArguments
        } else {
            proc.executableURL = resolvedURL
            proc.arguments = claudeArguments
        }
        proc.standardInput = secondaryHandle
        proc.standardOutput = secondaryHandle
        proc.standardError = secondaryHandle

        proc.currentDirectoryURL = workingDirectory
        var env = sessionIdentity.environment
        env["PWD"] = workingDirectory.path
        proc.environment = env

        guard TTYCommandRunner.beginActiveProcessLaunchForAppShutdown() else {
            try? primaryHandle.close()
            try? secondaryHandle.close()
            throw SessionError.launchFailed("App shutdown in progress")
        }
        defer { TTYCommandRunner.endActiveProcessLaunchForAppShutdown() }

        do {
            try proc.run()
            Self.log.debug(
                "Claude CLI session started",
                metadata: ["binary": resolvedURL.lastPathComponent])
        } catch {
            Self.log.warning("Claude CLI launch failed", metadata: ["error": error.localizedDescription])
            try? primaryHandle.close()
            try? secondaryHandle.close()
            throw SessionError.launchFailed(error.localizedDescription)
        }

        let pid = proc.processIdentifier
        guard TTYCommandRunner.registerActiveProcessForAppShutdown(
            pid: pid,
            binary: resolvedURL.lastPathComponent)
        else {
            proc.terminate()
            kill(pid, SIGKILL)
            try? primaryHandle.close()
            try? secondaryHandle.close()
            throw SessionError.launchFailed("App shutdown in progress")
        }

        var processGroup: pid_t?
        if setpgid(pid, pid) == 0 {
            processGroup = pid
            TTYCommandRunner.updateActiveProcessGroupForAppShutdown(pid: pid, processGroup: processGroup)
        }

        self.process = proc
        self.primaryFD = primaryFD
        self.primaryHandle = primaryHandle
        self.secondaryHandle = secondaryHandle
        self.processGroup = processGroup
        self.sessionIdentity = sessionIdentity
        self.startedAt = Date()
        // Only the dedicated probe directory may be trusted, never `probeWorkingDirectoryURL()`'s temporary fallback.
        self.launchedInProbeDirectory = ClaudeStatusProbe.isDedicatedProbeWorkingDirectory(workingDirectory)
        return false
    }

    static func isolatedProbeWorkingDirectoryURL() throws -> URL {
        let directory = ClaudeStatusProbe.preparedProbeWorkingDirectoryURL()
        guard ClaudeStatusProbe.isDedicatedProbeWorkingDirectory(directory) else {
            throw SessionError.ioFailed("Cannot prepare Claude's isolated probe directory.")
        }
        return directory
    }

    /// Opt usage probes out of Remote Control and the user's hooks without changing saved settings or managed policy.
    static let probeSettingsArguments = ["--settings", #"{"remoteControlAtStartup":false,"disableAllHooks":true}"#]

    static func launchArguments(sessionID: UUID) -> [String] {
        // Reuse a probe-owned ID: interactive `/usage` cannot use print-only no-persistence.
        // Ignore ambient MCP servers.
        ["--allowed-tools", "", "--strict-mcp-config"] + self.probeSettingsArguments + [
            "--session-id", sessionID.uuidString.lowercased(),
        ]
    }

    static func loadOrCreateProbeSessionID(
        in directory: URL,
        fileManager fm: FileManager = .default) -> UUID
    {
        let url = directory.appendingPathComponent(".codexbar-session-id", isDirectory: false)
        if let raw = try? String(contentsOf: url, encoding: .utf8),
           let existing = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            return existing
        }

        let sessionID = UUID()
        do {
            try fm.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try sessionID.uuidString.lowercased().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Self.log.warning(
                "Claude probe session identity persistence failed",
                metadata: ["error": error.localizedDescription])
            return self.fallbackProbeSessionID
        }

        #if os(macOS) || os(Linux)
        do {
            try fm.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: url.path)
        } catch {
            Self.log.warning(
                "Claude probe session identity permission hardening failed",
                metadata: ["error": error.localizedDescription])
        }
        #endif
        return sessionID
    }

    static func launchEnvironment(baseEnv: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = self.scrubbedClaudeEnvironment(from: TTYCommandRunner.enrichedEnvironment(baseEnv: baseEnv))
        // Passive status and auth probes must not mutate or update the user's Claude CLI installation.
        env["DISABLE_AUTOUPDATER"] = "1"
        return env
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

        let descendants = self.process.map { TTYProcessTreeTerminator.descendantPIDs(of: $0.processIdentifier) } ?? []
        if let proc = self.process, proc.isRunning {
            proc.terminate()
        }
        if let proc = self.process {
            TTYProcessTreeTerminator.terminateProcessTree(
                rootPID: proc.processIdentifier,
                processGroup: self.processGroup,
                signal: SIGTERM,
                knownDescendants: descendants)
        }
        let waitDeadline = Date().addingTimeInterval(1.0)
        if let proc = self.process {
            while proc.isRunning, Date() < waitDeadline {
                usleep(100_000)
            }
            if proc.isRunning {
                TTYProcessTreeTerminator.terminateProcessTree(
                    rootPID: proc.processIdentifier,
                    processGroup: self.processGroup,
                    signal: SIGKILL,
                    knownDescendants: descendants)
            } else {
                for pid in descendants where pid > 0 {
                    kill(pid, SIGKILL)
                }
            }
            TTYCommandRunner.unregisterActiveProcessForAppShutdown(pid: proc.processIdentifier)
            ProcessExitRelease.afterExit(proc)
        }

        self.process = nil
        self.primaryHandle = nil
        self.secondaryHandle = nil
        self.primaryFD = -1
        self.processGroup = nil
        self.sessionIdentity = nil
        self.startedAt = nil
        self.launchedInProbeDirectory = false
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

    private func sendPeriodicEnterIfNeeded(every: TimeInterval?, lastEnterAt: inout Date) {
        guard let every, Date().timeIntervalSince(lastEnterAt) >= every else { return }
        try? self.send("\r")
        lastEnterAt = Date()
    }

    private func send(_ text: String) throws {
        try self.writeAllToPrimary(Data(text.utf8))
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
                if written == 0 {
                    break
                }

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
