import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum TestProcessCleanup {
    static func register() {
        atexit(_testProcessCleanupAtExit)
    }

    fileprivate static func terminateLeakedCodexAppServers() {
        let pids = Self.pids(matchingFullCommandRegex: "codex.*app-server")
            .filter { $0 > 0 && $0 != getpid() }
        guard !pids.isEmpty else { return }

        for pid in pids {
            _ = kill(pid, SIGTERM)
        }

        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            let stillRunning = pids.contains(where: { kill($0, 0) == 0 })
            if !stillRunning { return }
            usleep(50000)
        }

        for pid in pids where kill(pid, 0) == 0 {
            _ = kill(pid, SIGKILL)
        }
    }

    private static func pids(matchingFullCommandRegex regex: String) -> [pid_t] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["pgrep", "-f", regex]

        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = Pipe()
        proc.standardInput = nil

        do {
            try proc.run()
        } catch {
            return []
        }
        proc.waitUntilExit()

        // Exit code 1 = "no processes matched".
        if proc.terminationStatus != 0 { return [] }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0) }
            .map { pid_t($0) }
    }
}

private let _registerTestProcessCleanup: Void = TestProcessCleanup.register()

@_cdecl("codexbar_test_cleanup_atexit")
private func _testProcessCleanupAtExit() {
    TestProcessCleanup.terminateLeakedCodexAppServers()
}
