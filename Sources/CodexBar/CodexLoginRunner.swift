import CodexBarCore
import Darwin
import Foundation

struct CodexLoginRunner {
    struct Result: Equatable {
        enum Outcome: Equatable {
            case success
            case timedOut
            case failed(status: Int32)
            case missingBinary
            case launchFailed(String)
        }

        let outcome: Outcome
        let output: String
    }

    static func run(
        homePath: String? = nil,
        timeout: TimeInterval = 120,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        loginPATH: [String]? = LoginShellPathCache.shared.current) async -> Result
    {
        await Task(priority: .userInitiated) {
            var env = environment
            env["PATH"] = PathBuilder.effectivePATH(
                purposes: [.rpc, .tty, .nodeTooling],
                env: env,
                loginPATH: loginPATH)
            env = CodexHomeScope.scopedEnvironment(base: env, codexHome: homePath)

            guard let executable = BinaryLocator.resolveCodexBinary(
                env: env,
                loginPATH: loginPATH)
            else {
                return Result(outcome: .missingBinary, output: "")
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable, "login"]
            process.environment = env

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let termination = ProcessTermination()
            process.terminationHandler = { _ in
                termination.resolve(timedOut: false)
            }

            var processGroup: pid_t?
            do {
                try process.run()
                processGroup = self.attachProcessGroup(process)
            } catch {
                return Result(outcome: .launchFailed(error.localizedDescription), output: "")
            }

            let timedOut = await self.wait(timeout: timeout, termination: termination)
            if timedOut {
                self.terminate(process, processGroup: processGroup)
            }

            let output = await self.combinedOutput(stdout: stdout, stderr: stderr)
            if timedOut {
                return Result(outcome: .timedOut, output: output)
            }

            let status = process.terminationStatus
            if status == 0 {
                return Result(outcome: .success, output: output)
            }
            return Result(outcome: .failed(status: status), output: output)
        }.value
    }

    private final class ProcessTermination: @unchecked Sendable {
        private let lock = NSLock()
        private var timedOut: Bool?
        private var continuation: CheckedContinuation<Bool, Never>?

        func resolve(timedOut: Bool) {
            let continuation: CheckedContinuation<Bool, Never>?
            self.lock.lock()
            guard self.timedOut == nil else {
                self.lock.unlock()
                return
            }
            self.timedOut = timedOut
            continuation = self.continuation
            self.continuation = nil
            self.lock.unlock()
            continuation?.resume(returning: timedOut)
        }

        func wait() async -> Bool {
            await withCheckedContinuation { continuation in
                let timedOut: Bool?
                self.lock.lock()
                timedOut = self.timedOut
                if timedOut == nil {
                    self.continuation = continuation
                }
                self.lock.unlock()

                if let timedOut {
                    continuation.resume(returning: timedOut)
                }
            }
        }
    }

    private static func wait(timeout: TimeInterval, termination: ProcessTermination) async -> Bool {
        let timeoutTask = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: self.timeoutNanoseconds(timeout))
            if Task.isCancelled == false {
                termination.resolve(timedOut: true)
            }
        }
        let timedOut = await termination.wait()
        timeoutTask.cancel()
        return timedOut
    }

    private static func timeoutNanoseconds(_ timeout: TimeInterval) -> UInt64 {
        guard timeout.isFinite else { return UInt64.max }
        let seconds = max(0, min(timeout, Double(UInt64.max) / 1_000_000_000))
        return UInt64(seconds * 1_000_000_000)
    }

    private static func terminate(_ process: Process, processGroup: pid_t?) {
        if let pgid = processGroup {
            kill(-pgid, SIGTERM)
        }
        if process.isRunning {
            process.terminate()
        }

        let deadline = Date().addingTimeInterval(2.0)
        while process.isRunning, Date() < deadline {
            usleep(100_000)
        }

        if process.isRunning {
            if let pgid = processGroup {
                kill(-pgid, SIGKILL)
            }
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private static func attachProcessGroup(_ process: Process) -> pid_t? {
        let pid = process.processIdentifier
        return setpgid(pid, pid) == 0 ? pid : nil
    }

    private static func combinedOutput(stdout: Pipe, stderr: Pipe) async -> String {
        async let out = self.readToEnd(stdout)
        async let err = self.readToEnd(stderr)
        let stdoutText = await out
        let stderrText = await err

        let merged: String = if !stdoutText.isEmpty, !stderrText.isEmpty {
            [stdoutText, stderrText].joined(separator: "\n")
        } else {
            stdoutText + stderrText
        }
        let trimmed = merged.trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = trimmed.prefix(4000)
        return limited.isEmpty ? L("No output captured.") : String(limited)
    }

    private static func readToEnd(_ pipe: Pipe, timeout: TimeInterval = 3.0) async -> String {
        await withTaskGroup(of: String?.self) { group -> String in
            group.addTask {
                if #available(macOS 13.0, *) {
                    if let data = try? pipe.fileHandleForReading.readToEnd() { return self.decode(data) }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return Self.decode(data)
            }
            group.addTask {
                let nanos = UInt64(max(0, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                return nil
            }
            let result = await group.next()
            group.cancelAll()
            if let result, let text = result { return text }
            return ""
        }
    }

    private static func decode(_ data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}
