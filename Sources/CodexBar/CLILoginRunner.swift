import CodexBarCore
import Darwin
import Foundation

/// Owns the lifecycle of CLI logins that wait for browser approval and retain diagnostic output on failure.
enum CLILoginRunner {
    struct Result: Equatable, Sendable {
        enum Outcome: Equatable, Sendable {
            case success
            case cancelled
            case timedOut
            case failed(status: Int32)
            case missingBinary
            case launchFailed(String)
        }

        let outcome: Outcome
        let output: String
    }

    static func run(
        executable: String?,
        environment: [String: String],
        timeout: TimeInterval,
        outputDrainTimeout: TimeInterval,
        onProgress: (@Sendable (String) -> Void)? = nil) async -> Result
    {
        guard !Task.isCancelled else { return Result(outcome: .cancelled, output: "") }
        guard let executable else { return Result(outcome: .missingBinary, output: "") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable, "login"]
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdoutCapture = ProcessPipeCapture(pipe: stdout)
        let stderrCapture = ProcessPipeCapture(pipe: stderr)
        defer {
            stdoutCapture.stop()
            stderrCapture.stop()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
        }

        let termination = ProcessTermination()
        process.terminationHandler = { process in
            termination.resolve(process.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            return Result(outcome: .launchFailed(error.localizedDescription), output: "")
        }
        let pid = process.processIdentifier
        let processGroup: pid_t? = setpgid(pid, pid) == 0 ? pid : nil
        stdoutCapture.start()
        stderrCapture.start()

        let progressTask = onProgress.map { onProgress in
            Task {
                await self.pollProgress(stdout: stdoutCapture, stderr: stderrCapture, onProgress: onProgress)
            }
        }
        let exitTask = Task<Int32, Error> { await termination.wait() }
        let join = BoundedTaskJoin(sourceTask: exitTask)
        let outcome: Result.Outcome
        switch await join.value(joinGrace: self.duration(timeout)) {
        case let .value(status):
            outcome = status == 0 ? .success : .failed(status: status)
        case .failure:
            outcome = .cancelled
            SubprocessRunner.terminateProcess(process, processGroup: processGroup)
        case .timedOut:
            outcome = .timedOut
            SubprocessRunner.terminateProcess(process, processGroup: processGroup)
        }
        progressTask?.cancel()
        await progressTask?.value

        async let outData = stdoutCapture.finish(timeout: self.duration(outputDrainTimeout))
        async let errData = stderrCapture.finish(timeout: self.duration(outputDrainTimeout))
        let output = await self.combinedOutput(stdout: outData, stderr: errData)
        return Result(outcome: outcome, output: output.isEmpty ? L("No output captured.") : String(output.prefix(4000)))
    }

    private static func duration(_ timeout: TimeInterval) -> Duration {
        // Bound before converting floating-point seconds; infinity and rounded integer limits must not trap.
        let maximumSeconds = Double(Int64.max / 1_000_000_000)
        return .seconds(timeout.isFinite ? max(0, min(timeout, maximumSeconds)) : maximumSeconds)
    }

    private static func combinedOutput(stdout: Data, stderr: Data) -> String {
        let out = ProcessPipeCapture.decodeUTF8(stdout)
        let err = ProcessPipeCapture.decodeUTF8(stderr)
        let merged = out.isEmpty || err.isEmpty ? out + err : out + "\n" + err
        return merged.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func pollProgress(
        stdout: ProcessPipeCapture,
        stderr: ProcessPipeCapture,
        onProgress: @escaping @Sendable (String) -> Void) async
    {
        while !Task.isCancelled {
            let output = self.combinedOutput(stdout: stdout.currentSnapshot(), stderr: stderr.currentSnapshot())
            if output.contains("http://") || output.contains("https://") {
                guard !Task.isCancelled else { return }
                onProgress(output)
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
        }
    }
}
