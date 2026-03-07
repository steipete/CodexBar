#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

public enum SubprocessRunnerError: LocalizedError, Sendable {
    case binaryNotFound(String)
    case launchFailed(String)
    case timedOut(String)
    case nonZeroExit(code: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case let .binaryNotFound(binary):
            return "Missing CLI '\(binary)'. Install it and restart CodexBar."
        case let .launchFailed(details):
            return "Failed to launch process: \(details)"
        case let .timedOut(label):
            return "Command timed out: \(label)"
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

    public static func run(
        binary: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        label: String) async throws -> SubprocessResult
    {
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw SubprocessRunnerError.binaryNotFound(binary)
        }

        let start = Date()
        let binaryName = URL(fileURLWithPath: binary).lastPathComponent
        self.log.debug(
            "Subprocess start",
            metadata: ["label": label, "binary": binaryName, "timeout": "\(timeout)"])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = environment

        var processGroup: pid_t? = nil
        var exitCodeTask: Task<Int32, Never>? = nil

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        // Create asynchronous tasks to read from stdout and stderr.
        // Using readToEnd() in a separate task ensures we capture all output without blocking the main execution.
        let stdoutTask = Task<Data, Never> {
            (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        }
        let stderrTask = Task<Data, Never> {
            (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        }

        defer {
            // CRITICAL: Ensure the process is actually killed on exit/error/timeout.
            if process.isRunning {
                self.log.debug("Subprocess cleanup: terminating running process", metadata: ["label": label])
                process.terminate()
                if let pgid = processGroup {
                    kill(-pgid, SIGTERM)
                }
                
                // Give it a brief window to exit gracefully before SIGKILL.
                let killDeadline = Date().addingTimeInterval(0.4)
                while process.isRunning, Date() < killDeadline {
                    usleep(50000)
                }
                
                if process.isRunning {
                    self.log.warning("Subprocess cleanup: process resisted SIGTERM, sending SIGKILL", metadata: ["label": label])
                    if let pgid = processGroup {
                        kill(-pgid, SIGKILL)
                    }
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            
            // Cancel tasks to avoid leaking resources.
            exitCodeTask?.cancel()
            stdoutTask.cancel()
            stderrTask.cancel()
            
            // Ensure pipes are closed on exit to unblock any pending read operations.
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
        }

        do {
            try process.run()
        } catch {
            self.log.error("Subprocess launch failed", metadata: ["label": label, "error": error.localizedDescription])
            throw SubprocessRunnerError.launchFailed(error.localizedDescription)
        }

        let pid = process.processIdentifier
        if setpgid(pid, pid) == 0 {
            processGroup = pid
        }

        // Wait for the process to exit or the timeout to fire.
        let task = Task<Int32, Never> {
            process.waitUntilExit()
            return process.terminationStatus
        }
        exitCodeTask = task

        let exitCode = try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                self.log.warning("Subprocess timed out", metadata: ["label": label, "timeout": "\(timeout)"])
                throw SubprocessRunnerError.timedOut(label)
            }
            let code = try await group.next()!
            group.cancelAll()
            return code
        }

        // IMPORTANT: We close the pipes BEFORE awaiting the reading tasks.
        // readToEnd() can block indefinitely if the underlying process is dead but the pipe is still "open" 
        // in a zombie state or if a child process inherited it. Closing the handle explicitly triggers EOF 
        // in the reading task, allowing stdoutTask.value to complete.
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()

        let stdoutData = await stdoutTask.value
        let stderrData = await stderrTask.value
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        if exitCode != 0 {
            let duration = Date().timeIntervalSince(start)
            self.log.warning(
                "Subprocess failed",
                metadata: [
                    "label": label,
                    "binary": binaryName,
                    "status": "\(exitCode)",
                    "duration_ms": "\(Int(duration * 1000))",
                ])
            throw SubprocessRunnerError.nonZeroExit(code: exitCode, stderr: stderr)
        }

        let duration = Date().timeIntervalSince(start)
        self.log.debug(
            "Subprocess exit",
            metadata: [
                "label": label,
                "binary": binaryName,
                "status": "\(exitCode)",
                "duration_ms": "\(Int(duration * 1000))",
            ])
        return SubprocessResult(stdout: stdout, stderr: stderr)
    }
}
