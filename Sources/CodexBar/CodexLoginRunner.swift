import CodexBarCore
import Darwin
import Foundation

struct CodexLoginRunner {
    struct Result {
        enum Outcome {
            case success
            case timedOut
            case failed(status: Int32)
            case missingBinary
            case launchFailed(String)
        }

        let outcome: Outcome
        let output: String
    }

    static func run(homePath: String? = nil, timeout: TimeInterval = 120) async -> Result {
        await Task(priority: .userInitiated) {
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = PathBuilder.effectivePATH(
                purposes: [.rpc, .tty, .nodeTooling],
                env: env,
                loginPATH: LoginShellPathCache.shared.current)
            env = CodexHomeScope.scopedEnvironment(base: env, codexHome: homePath)

            guard let executable = BinaryLocator.resolveCodexBinary(
                env: env,
                loginPATH: LoginShellPathCache.shared.current)
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

            var processGroup: pid_t?
            do {
                try process.run()
                processGroup = self.attachProcessGroup(process)
            } catch {
                return Result(outcome: .launchFailed(error.localizedDescription), output: "")
            }

            let timedOut = await self.wait(for: process, timeout: timeout)
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

    private static func wait(for process: Process, timeout: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                process.waitUntilExit()
                return false
            }
            group.addTask {
                let nanos = UInt64(max(0, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                return true
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
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
        return limited.isEmpty ? "No output captured." : String(limited)
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
