#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

public enum SubprocessRunnerError: LocalizedError, Sendable {
    case binaryNotFound(String)
    case launchFailed(String)
    case timedOut(String)
    case outputTooLarge(String)
    case nonZeroExit(code: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case let .binaryNotFound(binary):
            return "Missing CLI '\(binary)'. Install it and restart CodexBar."
        case let .launchFailed(details):
            return "Failed to launch process: \(details)"
        case let .timedOut(label):
            return "Command timed out: \(label)"
        case let .outputTooLarge(label):
            return "Command produced too much output: \(label)"
        case let .nonZeroExit(code, stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Command failed with exit code \(code)."
            }
            return "Command failed (\(code)): \(trimmed)"
        }
    }
}

public struct SubprocessResult: Sendable {
    public let stdout: String
    public let stderr: String
}

public enum SubprocessRunner {
    private static let log = CodexBarLog.logger(LogCategories.subprocess)
    private static let timeoutQueue = DispatchQueue(
        label: "com.steipete.codexbar.subprocess.timeout",
        qos: .userInitiated,
        attributes: .concurrent)

    /// Thread-safe flag for communicating between concurrent tasks (e.g. timeout → caller).
    private final class KillFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            self.lock.withLock { self.value = true }
        }

        var isSet: Bool {
            self.lock.withLock { self.value }
        }
    }

    private final class TimeoutTimer: @unchecked Sendable {
        private let timer: any DispatchSourceTimer

        init(timer: any DispatchSourceTimer) {
            self.timer = timer
        }

        func cancel() {
            self.timer.cancel()
        }
    }

    private static func timeoutInterval(_ timeout: TimeInterval) -> DispatchTimeInterval {
        guard timeout.isFinite else {
            return .seconds(Int.max)
        }
        let nanoseconds = max(0, timeout * 1_000_000_000).rounded(.towardZero)
        return .nanoseconds(Int(exactly: nanoseconds) ?? Int.max)
    }

    /// Terminates a process and its process group, escalating from SIGTERM to SIGKILL.
    /// Returns `true` if the process was actually killed, `false` if it had already exited.
    @discardableResult
    package static func terminateProcess(_ process: Process, processGroup: pid_t?) -> Bool {
        guard process.isRunning else { return false }
        let descendants = TTYProcessTreeTerminator.descendantPIDs(of: process.processIdentifier)
        let descendantIdentities = descendants.compactMap(TTYProcessTreeTerminator.processIdentity(for:))
        TTYProcessTreeTerminator.terminateProcessTree(
            rootPID: process.processIdentifier,
            processGroup: processGroup,
            signal: SIGTERM,
            knownDescendants: descendants)
        let killDeadline = Date().addingTimeInterval(0.4)
        while process.isRunning, Date() < killDeadline {
            usleep(50000)
        }
        if process.isRunning {
            let currentDescendants = descendantIdentities
                .filter(TTYProcessTreeTerminator.isCurrent(_:))
                .map(\.pid)
            TTYProcessTreeTerminator.terminateProcessTree(
                rootPID: process.processIdentifier,
                processGroup: processGroup,
                signal: SIGKILL,
                knownDescendants: currentDescendants)
            let reapDeadline = Date().addingTimeInterval(0.4)
            while process.isRunning, Date() < reapDeadline {
                usleep(50000)
            }
        } else {
            for identity in descendantIdentities where TTYProcessTreeTerminator.isCurrent(identity) {
                kill(identity.pid, SIGKILL)
            }
        }
        return true
    }

    // MARK: - Public API

    /// Runs a process to natural exit without letting caller cancellation or a
    /// forced timeout interrupt an external mutation after launch.
    public static func runToCompletion(
        binary: String,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL? = nil,
        acceptsNonZeroExit: Bool = false,
        label: String) async throws -> SubprocessResult
    {
        let task = Task.detached(priority: .userInitiated) {
            try await self.run(
                binary: binary,
                arguments: arguments,
                environment: environment,
                timeout: .infinity,
                currentDirectoryURL: currentDirectoryURL,
                acceptsNonZeroExit: acceptsNonZeroExit,
                label: label)
        }
        return try await task.value
    }

    public static func run(
        binary: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        // Preserve the legacy bounded-prefix capture when omitted. Structured-output callers can opt into
        // fail-closed rejection by supplying an explicit limit.
        maxOutputBytes: Int? = nil,
        standardInput: Any? = nil,
        currentDirectoryURL: URL? = nil,
        acceptsNonZeroExit: Bool = false,
        // Mark this invocation so even detached descendants can be reaped after it exits.
        reapDescendants: Bool = false,
        label: String) async throws -> SubprocessResult
    {
        let executableURL = URL(fileURLWithPath: binary).standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw SubprocessRunnerError.binaryNotFound(binary)
        }

        let start = Date()
        let binaryName = executableURL.lastPathComponent
        func logMetadata(duration: TimeInterval, exitCode: Int32? = nil) -> [String: String] {
            var metadata = ["label": label, "binary": binaryName, "duration_ms": "\(Int(duration * 1000))"]
            if let exitCode { metadata["status"] = "\(exitCode)" }
            return metadata
        }
        self.log.debug(
            "Subprocess start",
            metadata: ["label": label, "binary": binaryName, "timeout": "\(timeout)"])

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        var launchEnvironment = environment
        launchEnvironment["PATH"] = PathBuilder.effectivePATH(purposes: [.tty], env: environment, loginPATH: nil)
        let ownership = reapDescendants ? ProcessOwnershipReaper() : nil
        process.environment = ownership
            .map { launchEnvironment.merging([ProcessOwnershipReaper.environmentKey: $0.marker]) { _, new in new } } ??
            launchEnvironment
        process.currentDirectoryURL = currentDirectoryURL

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = standardInput
        let normalizedMaxOutputBytes = maxOutputBytes.map { max(0, $0) }
        let captureMaxBytes = normalizedMaxOutputBytes.map { limit in
            limit == Int.max ? Int.max : limit + 1
        } ?? ProcessPipeCapture.defaultMaxBytes
        let stdoutCapture = ProcessPipeCapture(pipe: stdoutPipe, maxBytes: captureMaxBytes)
        let stderrCapture = ProcessPipeCapture(pipe: stderrPipe, maxBytes: captureMaxBytes)

        let termination = ProcessTermination()
        process.terminationHandler = { process in
            termination.resolve(process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            stdoutCapture.stop()
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrCapture.stop()
            stderrPipe.fileHandleForWriting.closeFile()
            throw SubprocessRunnerError.launchFailed(error.localizedDescription)
        }
        stdoutCapture.start()
        stderrCapture.start()

        let pid = process.processIdentifier
        let processGroup: pid_t? = setpgid(pid, pid) == 0 || getpgid(pid) == pid ? pid : nil
        defer { ownership?.reap(processGroup: processGroup) }

        let exitCodeTask = Task<Int32, Never> {
            await termination.wait()
        }

        let killedByTimeout = KillFlag()
        let timeoutTimerBox: TimeoutTimer? = if timeout.isFinite {
            {
                let timeoutTimer = DispatchSource.makeTimerSource(queue: self.timeoutQueue)
                timeoutTimer.schedule(deadline: .now() + self.timeoutInterval(timeout))
                timeoutTimer.setEventHandler {
                    guard process.isRunning else { return }
                    killedByTimeout.set()
                    self.terminateProcess(process, processGroup: processGroup)
                }
                timeoutTimer.resume()
                return TimeoutTimer(timer: timeoutTimer)
            }()
        } else {
            nil
        }

        do {
            let exitCode = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let code = await exitCodeTask.value
                try Task.checkCancellation()
                return code
            } onCancel: {
                timeoutTimerBox?.cancel()
                self.terminateProcess(process, processGroup: processGroup)
            }
            timeoutTimerBox?.cancel()

            let duration = Date().timeIntervalSince(start)
            // Race guard: the timeout timer may kill the process just before the
            // exit code arrives. Key off the explicit kill flag so a completed
            // process is not misclassified when the awaiting task resumes late.
            if killedByTimeout.isSet {
                self.log.warning(
                    "Subprocess timed out",
                    metadata: logMetadata(duration: duration))
                throw SubprocessRunnerError.timedOut(label)
            }

            async let stdoutData = stdoutCapture.finish(timeout: .seconds(1))
            async let stderrData = stderrCapture.finish(timeout: .seconds(1))
            let capturedStdout = await stdoutData
            let capturedStderr = await stderrData
            if let normalizedMaxOutputBytes,
               capturedStdout.count > normalizedMaxOutputBytes || capturedStderr.count > normalizedMaxOutputBytes
            {
                self.log.warning(
                    "Subprocess output exceeded memory limit",
                    metadata: ["label": label, "binary": binaryName])
                throw SubprocessRunnerError.outputTooLarge(label)
            }
            let stdout = ProcessPipeCapture.decodeUTF8(capturedStdout)
            let stderr = ProcessPipeCapture.decodeUTF8(capturedStderr)

            if exitCode != 0, !acceptsNonZeroExit {
                let duration = Date().timeIntervalSince(start)
                self.log.warning(
                    "Subprocess failed",
                    metadata: logMetadata(duration: duration, exitCode: exitCode))
                throw SubprocessRunnerError.nonZeroExit(code: exitCode, stderr: stderr)
            }

            self.log.debug(
                "Subprocess exit",
                metadata: logMetadata(duration: duration, exitCode: exitCode))
            return SubprocessResult(stdout: stdout, stderr: stderr)
        } catch {
            let duration = Date().timeIntervalSince(start)
            self.log.warning(
                "Subprocess error",
                metadata: logMetadata(duration: duration))
            // Safety net: ensure the process is dead (may already be killed by timeout timer).
            self.terminateProcess(process, processGroup: processGroup)
            exitCodeTask.cancel()
            stdoutCapture.stop()
            stderrCapture.stop()
            throw error
        }
    }
}
