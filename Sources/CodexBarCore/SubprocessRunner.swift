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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        let stdoutTask = Task<Data, Never> {
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrTask = Task<Data, Never> {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        do {
            try process.run()
        } catch {
            stdoutTask.cancel()
            stderrTask.cancel()
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            throw SubprocessRunnerError.launchFailed(error.localizedDescription)
        }

        var processGroup: pid_t?
        let pid = process.processIdentifier
        if setpgid(pid, pid) == 0 {
            processGroup = pid
        }

        let exitCodeTask = Task<Int32, Never> {
            process.waitUntilExit()
            return process.terminationStatus
        }

        do {
            let exitCode = try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask { await exitCodeTask.value }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw SubprocessRunnerError.timedOut(label)
                }
                let code = try await group.next()!
                group.cancelAll()
                return code
            }

            let stdoutData = await stdoutTask.value
            let stderrData = await stderrTask.value
            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""

            if exitCode != 0 {
                throw SubprocessRunnerError.nonZeroExit(code: exitCode, stderr: stderr)
            }

            return SubprocessResult(stdout: stdout, stderr: stderr)
        } catch {
            if process.isRunning {
                process.terminate()
                if let pgid = processGroup {
                    kill(-pgid, SIGTERM)
                }
                let killDeadline = Date().addingTimeInterval(0.4)
                while process.isRunning, Date() < killDeadline {
                    usleep(50000)
                }
                if process.isRunning {
                    if let pgid = processGroup {
                        kill(-pgid, SIGKILL)
                    }
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            exitCodeTask.cancel()
            stdoutTask.cancel()
            stderrTask.cancel()
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            throw error
        }
    }
}
