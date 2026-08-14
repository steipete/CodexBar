import Foundation

package enum RPCChildProcessTeardown {
    /// Tears down a JSON-RPC child spawned via Foundation `Process`.
    ///
    /// Closes the child's stdin first (codex app-server and grok agent stdio exit on EOF),
    /// then escalates SIGTERM -> bounded wait -> SIGKILL across the child's process tree via
    /// `SubprocessRunner.terminateProcess`, so children that ignore SIGTERM cannot leak
    /// (#2789). Foundation reaps the child once it exits, so no explicit waitpid is needed here.
    package static func terminate(process: Process, stdinPipe: Pipe) {
        try? stdinPipe.fileHandleForWriting.close()
        SubprocessRunner.terminateProcess(process, processGroup: nil)
    }
}
