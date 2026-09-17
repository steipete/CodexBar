#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// Cancellation requests guardian shutdown, then awaits its complete receiver-tree drain.
enum CodexRemoteLogMirrorProcess {
    static func run(_ command: CodexRemoteLogMirror.Command) async throws -> String {
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: command.binary) else {
            throw CodexRemoteLogError.missingDependency
        }
        let output = Pipe()
        let errors = Pipe()
        let stdout = ProcessPipeCapture(pipe: output, maxBytes: command.outputBytes + 1)
        let stderr = ProcessPipeCapture(pipe: errors, maxBytes: command.outputBytes + 1)
        let process: SpawnedProcessGroup
        do {
            process = try SpawnedProcessGroup.launch(
                binary: command.binary,
                arguments: command.arguments,
                environment: command.environment,
                stdoutPipe: output,
                stderrPipe: errors,
                standardInputDescriptor: command.lockDescriptor,
                retainExitedRoot: true)
        } catch {
            stdout.stop()
            stderr.stop()
            throw CodexRemoteLogError.missingDependency
        }
        stdout.start()
        stderr.start()
        let isGuardian = command.arguments.first == CodexRemoteLogGuardian.argument
        let control = CodexRemoteLogGuardianControl()
        // Detached only to keep cleanup awaits/sleeps operational when the caller is cancelled.
        // This task is always awaited; it never publishes or outlives the transaction owner.
        let completion = Task.detached {
            while process.isRunning {
                if control.isCancelled, !isGuardian { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            await process.terminateAndDrain()
            let bytes = await stdout.finish(timeout: .seconds(1))
            let diagnostic = await stderr.finish(timeout: .seconds(1))
            guard bytes.count <= command.outputBytes, diagnostic.count <= command.outputBytes else {
                throw CodexRemoteLogError.budgetExceeded
            }
            let status = process.terminationStatus ?? 74
            guard status == 0 else { throw Self.failure(status: status, kind: command.kind) }
            guard let string = String(data: bytes, encoding: .utf8) else {
                throw CodexRemoteLogError.invalidManifest
            }
            return string
        }
        return try await withTaskCancellationHandler {
            do {
                let result = try await completion.value
                try Task.checkCancellation()
                return result
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            control.cancel()
            // Do not kill the guardian's descendants here or force-kill the guardian before it drains.
            process.signalRootIfCurrent(SIGTERM)
        }
    }

    private static func failure(status: Int32, kind: CodexRemoteLogMirror.Command.Kind) -> CodexRemoteLogError {
        if kind == .transfer {
            switch status {
            case CodexRemoteLogGuardian.timeoutStatus: return .timedOut
            case CodexRemoteLogGuardian.cancelledStatus: return .cancelled
            case CodexRemoteLogGuardian.budgetStatus: return .budgetExceeded
            default: return .transferFailed
            }
        }
        switch status {
        case 42: return .missingDependency
        case 43: return .inaccessibleRoot
        case 44: return .unsafePath
        case 45: return .budgetExceeded
        case 46: return .unstableSource
        default: return .remoteUnavailable
        }
    }
}
