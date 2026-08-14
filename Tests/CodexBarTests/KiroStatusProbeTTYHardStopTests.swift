import Foundation
import Testing
@testable import CodexBarCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

#if DEBUG
extension KiroStatusProbeTests {
    @Test
    func `tty runner bounds hard stop while cleaning root TERM and third generation PTY holders`() async throws {
        let childPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-kiro-double-fork-\(UUID().uuidString).pid")
        let termChildPIDFile = childPIDFile.appendingPathExtension("term-child")
        let lateChildPIDFile = childPIDFile.appendingPathExtension("late-child")
        let rootTermChildPIDFile = childPIDFile.appendingPathExtension("root-term-child")
        let preKillSnapshotTriggerFile = childPIDFile.appendingPathExtension("pre-kill-snapshot")
        let cliURL = try self.makeHardStopCLI()
        defer {
            for pidFile in [childPIDFile, termChildPIDFile, lateChildPIDFile, rootTermChildPIDFile] {
                if let text = try? String(contentsOf: pidFile, encoding: .utf8),
                   let childPID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
                {
                    _ = kill(childPID, SIGKILL)
                }
                try? FileManager.default.removeItem(at: pidFile)
            }
            try? FileManager.default.removeItem(at: preKillSnapshotTriggerFile)
            try? FileManager.default.removeItem(at: cliURL.deletingLastPathComponent())
        }

        let hardStopBudget = 3 * TestTimingBudget.slowdownFactor
        // Repository wall-clock tests use 3 seconds locally and scale to 9 seconds on loaded CI runners. Keep
        // sequential discovery beyond that assertion in both environments without consuming the cleanup window.
        let discoveryDelay = hardStopBudget + 1
        let cleanupMaxLifetime = discoveryDelay + 15
        let preKillSnapshotTriggerPath = preKillSnapshotTriggerFile.path
        #expect(!FileManager.default.fileExists(atPath: preKillSnapshotTriggerPath))
        let start = Date()
        let result = try SpawnedProcessGroup.withOutputHolderDiscoveryDelayForTesting(discoveryDelay) {
            try SpawnedProcessGroup.withOutputHolderCleanupMaxLifetimeForTesting(cleanupMaxLifetime) {
                try SpawnedProcessGroup.withOutputHolderPreKillSnapshotHookForTesting {
                    Self.touchFile(atPath: preKillSnapshotTriggerPath)
                } operation: {
                    try SpawnedProcessGroup.withOutputHolderPreKillDelayForTesting(0.5) {
                        try TTYCommandRunner().run(
                            binary: cliURL.path,
                            send: "",
                            options: .init(
                                timeout: 4,
                                idleTimeout: 0.1,
                                extraArgs: [
                                    childPIDFile.path,
                                    termChildPIDFile.path,
                                    lateChildPIDFile.path,
                                    rootTermChildPIDFile.path,
                                    preKillSnapshotTriggerPath,
                                ],
                                initialDelay: 0,
                                settleAfterStop: 0))
                    }
                }
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        print("PTY hard-stop latency: \(String(format: "%.3f", elapsed))s")

        #expect(result.completion == .idleTimeout)
        let snapshot = try KiroStatusProbe().parse(output: result.text)
        #expect(snapshot.planName == "KIRO FREE")
        #expect(snapshot.creditsUsed == 12.50)
        #expect(
            elapsed < hardStopBudget,
            "Delayed holder discovery should not extend the PTY hard stop, took \(elapsed)s")

        let childPIDText = try String(contentsOf: childPIDFile, encoding: .utf8)
        let childPID = try #require(pid_t(childPIDText.trimmingCharacters(in: .whitespacesAndNewlines)))
        for _ in 0..<1000 where !FileManager.default.fileExists(atPath: termChildPIDFile.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let termChildPIDText = try String(contentsOf: termChildPIDFile, encoding: .utf8)
        let termChildPID = try #require(pid_t(termChildPIDText.trimmingCharacters(in: .whitespacesAndNewlines)))
        for _ in 0..<1000 where !FileManager.default.fileExists(atPath: lateChildPIDFile.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let lateChildPIDText = try String(contentsOf: lateChildPIDFile, encoding: .utf8)
        let lateChildPID = try #require(pid_t(lateChildPIDText.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(FileManager.default.fileExists(atPath: preKillSnapshotTriggerPath))
        for _ in 0..<1000 where !FileManager.default.fileExists(atPath: rootTermChildPIDFile.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let rootTermChildPIDText = try String(contentsOf: rootTermChildPIDFile, encoding: .utf8)
        let rootTermChildPID = try #require(
            pid_t(rootTermChildPIDText.trimmingCharacters(in: .whitespacesAndNewlines)))

        let cleanupDeadline = Date().addingTimeInterval(20)
        while kill(childPID, 0) == 0 || kill(termChildPID, 0) == 0 || kill(lateChildPID, 0) == 0
            || kill(rootTermChildPID, 0) == 0,
            Date() < cleanupDeadline
        {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(kill(childPID, 0) == -1)
        #expect(kill(termChildPID, 0) == -1)
        #expect(kill(lateChildPID, 0) == -1)
        #expect(kill(rootTermChildPID, 0) == -1)
    }

    @Test
    func `tty runner bounds hard stop when root exits during early stop settle`() async throws {
        let holderPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-kiro-settle-holder-\(UUID().uuidString).pid")
        let allowRootExitFile = holderPIDFile.appendingPathExtension("allow-root-exit")
        let rootExitedFile = holderPIDFile.appendingPathExtension("root-exited")
        let cliURL = try self.makeSettleExitHardStopCLI()
        defer {
            if let text = try? String(contentsOf: holderPIDFile, encoding: .utf8),
               let holderPID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                _ = kill(holderPID, SIGKILL)
            }
            for file in [holderPIDFile, allowRootExitFile, rootExitedFile] {
                try? FileManager.default.removeItem(at: file)
            }
            try? FileManager.default.removeItem(at: cliURL.deletingLastPathComponent())
        }

        let hardStopBudget = 3 * TestTimingBudget.slowdownFactor
        let discoveryDelay = hardStopBudget + 1
        let cleanupMaxLifetime = discoveryDelay + 15
        let allowRootExitPath = allowRootExitFile.path
        #expect(!FileManager.default.fileExists(atPath: allowRootExitPath))
        #expect(!FileManager.default.fileExists(atPath: rootExitedFile.path))

        let start = Date()
        let result = try SpawnedProcessGroup.withOutputHolderDiscoveryDelayForTesting(discoveryDelay) {
            try SpawnedProcessGroup.withOutputHolderCleanupMaxLifetimeForTesting(cleanupMaxLifetime) {
                try TTYCommandRunner().run(
                    binary: cliURL.path,
                    send: "",
                    options: .init(
                        timeout: 4 * TestTimingBudget.slowdownFactor,
                        idleTimeout: 0,
                        extraArgs: [holderPIDFile.path, allowRootExitPath, rootExitedFile.path],
                        initialDelay: 0,
                        settleAfterStop: 0.6 * TestTimingBudget.slowdownFactor),
                    onURLDetected: {
                        Self.touchFile(atPath: allowRootExitPath)
                    })
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        print("PTY settle-exit hard-stop latency: \(String(format: "%.3f", elapsed))s")

        #expect(result.completion == .processExited(status: 0))
        #expect(FileManager.default.fileExists(atPath: rootExitedFile.path))
        let snapshot = try KiroStatusProbe().parse(output: result.text)
        #expect(snapshot.planName == "KIRO FREE")
        #expect(snapshot.creditsUsed == 12.50)
        #expect(
            elapsed < hardStopBudget,
            "Delayed holder discovery should not extend cleanup after a settle exit, took \(elapsed)s")

        let holderPIDText = try String(contentsOf: holderPIDFile, encoding: .utf8)
        let holderPID = try #require(pid_t(holderPIDText.trimmingCharacters(in: .whitespacesAndNewlines)))
        let cleanupDeadline = Date().addingTimeInterval(20)
        while kill(holderPID, 0) == 0, Date() < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(kill(holderPID, 0) == -1)
    }

    private func makeHardStopCLI() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-kiro-cli-\(UUID().uuidString)", isDirectory: true)
        let cliURL = root.appendingPathComponent("kiro-cli")
        let script = """
        #!/usr/bin/python3
        import os
        import signal
        import sys
        import time

        root_term_handled = False
        def handle_root_term(_signal, _frame):
            global root_term_handled
            if root_term_handled:
                return
            root_term_handled = True
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            root_term_child = os.fork()
            if root_term_child == 0:
                os.setsid()
                signal.signal(signal.SIGHUP, signal.SIG_IGN)
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                with open(sys.argv[4], "w") as handle:
                    handle.write(str(os.getpid()))
                time.sleep(30)
                os._exit(0)
            time.sleep(0.2)
            os._exit(0)
        signal.signal(signal.SIGTERM, handle_root_term)
        intermediate = os.fork()
        if intermediate == 0:
            child = os.fork()
            if child > 0:
                os._exit(0)
            os.setsid()
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
            def handle_term(_signal, _frame):
                term_child = os.fork()
                if term_child == 0:
                    signal.signal(signal.SIGTERM, signal.SIG_IGN)
                    with open(sys.argv[2], "w") as handle:
                        handle.write(str(os.getpid()))
                    while not os.path.exists(sys.argv[5]):
                        time.sleep(0.01)
                    late_child = os.fork()
                    if late_child == 0:
                        with open(sys.argv[3], "w") as handle:
                            handle.write(str(os.getpid()))
                        time.sleep(30)
                        os._exit(0)
                    time.sleep(30)
                    os._exit(0)
                time.sleep(0.2)
                os._exit(0)
            signal.signal(signal.SIGTERM, handle_term)
            with open(sys.argv[1], "w") as handle:
                handle.write(str(os.getpid()))
            time.sleep(30)
            os._exit(0)

        os.waitpid(intermediate, 0)
        while not os.path.exists(sys.argv[1]):
            time.sleep(0.01)
        if os.path.exists(sys.argv[4]):
            raise RuntimeError("root TERM child started before TERM")
        if os.path.exists(sys.argv[5]):
            raise RuntimeError("pre-kill snapshot trigger existed before cleanup")
        print("Estimated Usage | resets on 2026-06-01 | KIRO FREE", flush=True)
        print("Credits (12.50 of 50 covered in plan)", flush=True)
        print("████████████████████ 25%", flush=True)
        time.sleep(30)
        """
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try script.write(to: cliURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliURL.path)
        return cliURL
    }

    private func makeSettleExitHardStopCLI() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-kiro-settle-cli-\(UUID().uuidString)", isDirectory: true)
        let cliURL = root.appendingPathComponent("kiro-cli")
        let script = """
        #!/usr/bin/python3
        import os
        import signal
        import sys
        import time

        intermediate = os.fork()
        if intermediate == 0:
            holder = os.fork()
            if holder > 0:
                os._exit(0)
            os.setsid()
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            with open(sys.argv[1], "w") as handle:
                handle.write(str(os.getpid()))
            time.sleep(30)
            os._exit(0)

        os.waitpid(intermediate, 0)
        while not os.path.exists(sys.argv[1]):
            time.sleep(0.01)
        print("Estimated Usage | resets on 2026-06-01 | KIRO FREE", flush=True)
        print("Credits (12.50 of 50 covered in plan)", flush=True)
        print("https://example.com/idle-stop-ready", flush=True)
        while not os.path.exists(sys.argv[2]):
            time.sleep(0.01)
        time.sleep(0.1)
        with open(sys.argv[3], "w") as handle:
            handle.write(str(os.getpid()))
        os._exit(0)
        """
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try script.write(to: cliURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliURL.path)
        return cliURL
    }

    private static func touchFile(atPath path: String) {
        let fileDescriptor = open(path, O_WRONLY | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else { return }
        _ = close(fileDescriptor)
    }
}
#endif
