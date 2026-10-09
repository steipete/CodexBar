import Foundation

package final class RPCChildProcessOutput: @unchecked Sendable {
    package let stdout = Pipe()
    package let stderr = Pipe()
    package let lines: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    package init() {
        (self.lines, self.continuation) = AsyncStream.makeStream()
    }

    package func start(
        process: Process,
        stdin: RPCChildProcessInput,
        onOversizedLine: @escaping @Sendable () -> Void,
        onStderr: @escaping @Sendable (Substring) -> Void)
    {
        let continuation = self.continuation
        let buffer = BoundedLineBuffer()
        self.stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            let result = buffer.appendAndDrainLines(data)
            if result.didExceedLimit {
                onOversizedLine()
                handle.readabilityHandler = nil
                DispatchQueue.global(qos: .userInitiated).async {
                    RPCChildProcessTeardown.terminate(process: process, stdin: stdin)
                }
                continuation.finish()
                return
            }
            for line in result.lines {
                continuation.yield(line)
            }
        }
        self.stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // Clear EOF handlers so closed pipes cannot keep scheduling empty reads.
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            for line in text.split(whereSeparator: \.isNewline) {
                onStderr(line)
            }
        }
    }
}
