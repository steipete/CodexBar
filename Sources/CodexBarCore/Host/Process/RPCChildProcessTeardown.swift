#if canImport(Darwin)
import Darwin
#endif
import Foundation

package final class RPCChildProcessInput: @unchecked Sendable {
    package let pipe = Pipe()

    private let lock = NSLock()
    private var isClosed = false

    package init() {
        #if canImport(Darwin)
        // Keep broken pipes catchable instead of terminating the app with SIGPIPE.
        _ = fcntl(self.pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        #endif
    }

    package func write(_ data: Data) throws {
        try self.lock.withLock {
            guard !self.isClosed else {
                throw CocoaError(.fileWriteUnknown)
            }
            try self.pipe.fileHandleForWriting.write(contentsOf: data)
        }
    }

    package func close() {
        self.lock.withLock {
            guard !self.isClosed else { return }
            self.isClosed = true
            try? self.pipe.fileHandleForWriting.close()
        }
    }
}

package enum RPCChildProcessTeardown {
    /// Tears down a JSON-RPC child spawned via Foundation `Process`.
    ///
    /// Closes the child's stdin first (codex app-server and grok agent stdio exit on EOF),
    /// then escalates SIGTERM -> bounded wait -> SIGKILL across the child's process tree via
    /// `SubprocessRunner.terminateProcess`, so children that ignore SIGTERM cannot leak
    /// (#2789). Foundation reaps the child once it exits, so no explicit waitpid is needed here.
    package static func terminate(process: Process, stdin: RPCChildProcessInput) {
        stdin.close()
        SubprocessRunner.terminateProcess(process, processGroup: nil)
    }
}
