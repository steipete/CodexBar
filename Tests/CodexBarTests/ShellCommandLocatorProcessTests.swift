#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import Testing
@testable import CodexBarCore

struct ShellCommandLocatorProcessTests {
    @Test
    func `shell probe pipe descriptors close across unrelated execs`() throws {
        let fds = try #require(ShellCommandLocator.test_makeCloseOnExecPipe())
        defer {
            close(fds.read)
            close(fds.write)
        }

        for fd in [fds.read, fds.write] {
            let flags = fcntl(fd, F_GETFD)
            #expect(flags >= 0)
            #expect(flags & FD_CLOEXEC != 0)
        }
    }

    @Test
    func `shell runner terminates session escaped partial output holders after timeout`() throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-shell-runner-timeout-\(UUID().uuidString)")
            .path
        let stdoutPIDFile = "\(pidFile).stdout"
        let stderrPIDFile = "\(pidFile).stderr"
        let script = """
        import os
        import signal
        import sys
        import time

        for stream, suffix in ((1, ".stdout"), (2, ".stderr")):
            child = os.fork()
            if child == 0:
                os.setsid()
                signal.signal(signal.SIGHUP, signal.SIG_IGN)
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                os.close(2 if stream == 1 else 1)
                with open(sys.argv[1] + suffix, "w") as handle:
                    handle.write(str(os.getpid()))
                while True:
                    time.sleep(1)

        while not all(os.path.exists(sys.argv[1] + suffix) for suffix in (".stdout", ".stderr")):
            time.sleep(0.01)
        time.sleep(1000)
        """

        let start = Date()
        let data = ShellCommandLocator.test_runShellCommand(
            shell: "/usr/bin/python3",
            arguments: ["-c", script, pidFile],
            timeout: 0.2)
        let elapsed = Date().timeIntervalSince(start)

        let pids = try [stdoutPIDFile, stderrPIDFile].map { file in
            let pidText = try String(contentsOfFile: file, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return try #require(pid_t(pidText))
        }
        defer {
            for pid in pids {
                kill(pid, SIGKILL)
            }
            for file in [stdoutPIDFile, stderrPIDFile] {
                try? FileManager.default.removeItem(atPath: file)
            }
        }

        #expect(data == nil)
        #expect(elapsed < 3.0, "Timed-out PATH probes should remain bounded")
        for pid in pids {
            #expect(kill(pid, 0) != 0)
        }
    }
}
