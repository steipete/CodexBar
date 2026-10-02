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
        let fixtureReadyFile = childPIDFile.appendingPathExtension("ready")
        let beginOutputFile = childPIDFile.appendingPathExtension("begin-output")
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
            for file in [preKillSnapshotTriggerFile, fixtureReadyFile, beginOutputFile] {
                try? FileManager.default.removeItem(at: file)
            }
            try? FileManager.default.removeItem(at: cliURL.deletingLastPathComponent())
        }

        let releaseDiscovery = DispatchSemaphore(value: 0)
        let discoveryStarted = KiroTestCompletionMarker()
        defer { releaseDiscovery.signal() }
        let preKillSnapshotTriggerPath = preKillSnapshotTriggerFile.path
        #expect(!FileManager.default.fileExists(atPath: preKillSnapshotTriggerPath))
        let runnerTask = Task.detached {
            try SpawnedProcessGroup.withOutputHolderDiscoveryHookForTesting {
                discoveryStarted.markCompleted()
                #expect(releaseDiscovery.wait(timeout: .now() + 20) == .success)
            } operation: {
                try SpawnedProcessGroup.withOutputHolderCleanupMaxLifetimeForTesting(60) {
                    try SpawnedProcessGroup.withOutputHolderPreKillSnapshotHookForTesting {
                        try? KiroProcessTestSupport.touch(preKillSnapshotTriggerFile)
                        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
                        while KiroProcessTestSupport.readPID(from: lateChildPIDFile) == nil,
                              ContinuousClock.now < deadline
                        {
                            Thread.sleep(forTimeInterval: 0.01)
                        }
                        #expect(KiroProcessTestSupport.readPID(from: lateChildPIDFile) != nil)
                    } operation: {
                        try TTYCommandRunner().run(
                            binary: "/usr/bin/python3",
                            send: "",
                            options: .init(
                                timeout: 30,
                                idleTimeout: 0.1,
                                extraArgs: [
                                    "-S", cliURL.path,
                                    childPIDFile.path,
                                    termChildPIDFile.path,
                                    lateChildPIDFile.path,
                                    rootTermChildPIDFile.path,
                                    preKillSnapshotTriggerPath,
                                    fixtureReadyFile.path,
                                    beginOutputFile.path,
                                ],
                                initialDelay: 0,
                                settleAfterStop: 0))
                    }
                }
            }
        }
        do {
            try await KiroProcessTestSupport.waitForFile(fixtureReadyFile)
        } catch {
            runnerTask.cancel()
            _ = try? await runnerTask.value
            throw error
        }
        try KiroProcessTestSupport.touch(beginOutputFile)
        let result = try await runnerTask.value
        try await KiroProcessTestSupport.waitForCondition("holder discovery to reach the gate") {
            discoveryStarted.isCompleted()
        }
        let childPID = try await KiroProcessTestSupport.waitForPID(in: childPIDFile)
        #expect(kill(childPID, 0) == 0)
        releaseDiscovery.signal()

        #expect(result.completion == .idleTimeout)
        let snapshot = try KiroStatusProbe().parse(output: result.text)
        #expect(snapshot.planName == "KIRO FREE")
        #expect(snapshot.creditsUsed == 12.50)
        let termChildPID = try await KiroProcessTestSupport.waitForPID(in: termChildPIDFile)
        let lateChildPID = try await KiroProcessTestSupport.waitForPID(in: lateChildPIDFile)
        #expect(FileManager.default.fileExists(atPath: preKillSnapshotTriggerPath))
        let rootTermChildPID = try await KiroProcessTestSupport.waitForPID(in: rootTermChildPIDFile)

        try await KiroProcessTestSupport.waitForExit(
            of: [childPID, termChildPID, lateChildPID, rootTermChildPID],
            timeout: .seconds(20),
            description: "all delayed PTY holder cleanup processes to exit")
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
        let fixtureReadyFile = holderPIDFile.appendingPathExtension("ready")
        let beginOutputFile = holderPIDFile.appendingPathExtension("begin-output")
        let cliURL = try self.makeSettleExitHardStopCLI()
        defer {
            if let text = try? String(contentsOf: holderPIDFile, encoding: .utf8),
               let holderPID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                _ = kill(holderPID, SIGKILL)
            }
            for file in [holderPIDFile, allowRootExitFile, rootExitedFile, fixtureReadyFile, beginOutputFile] {
                try? FileManager.default.removeItem(at: file)
            }
            try? FileManager.default.removeItem(at: cliURL.deletingLastPathComponent())
        }

        let releaseDiscovery = DispatchSemaphore(value: 0)
        let discoveryStarted = KiroTestCompletionMarker()
        defer { releaseDiscovery.signal() }
        let allowRootExitPath = allowRootExitFile.path
        #expect(!FileManager.default.fileExists(atPath: allowRootExitPath))
        #expect(!FileManager.default.fileExists(atPath: rootExitedFile.path))

        let runnerTask = Task.detached {
            try SpawnedProcessGroup.withOutputHolderDiscoveryHookForTesting {
                discoveryStarted.markCompleted()
                #expect(releaseDiscovery.wait(timeout: .now() + 20) == .success)
            } operation: {
                try SpawnedProcessGroup.withOutputHolderCleanupMaxLifetimeForTesting(60) {
                    try TTYCommandRunner.withEarlyStopSettleOverrideForTesting { process in
                        try KiroProcessTestSupport.touch(allowRootExitFile)
                        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
                        while process.isRunning, ContinuousClock.now < deadline {
                            Thread.sleep(forTimeInterval: 0.01)
                        }
                        #expect(!process.isRunning)
                    } operation: {
                        try TTYCommandRunner().run(
                            binary: "/usr/bin/python3",
                            send: "",
                            options: .init(
                                timeout: 30,
                                extraArgs: [
                                    "-S", cliURL.path,
                                    holderPIDFile.path,
                                    allowRootExitPath,
                                    rootExitedFile.path,
                                    fixtureReadyFile.path,
                                    beginOutputFile.path,
                                ],
                                initialDelay: 0,
                                stopOnURL: true,
                                settleAfterStop: 0))
                    }
                }
            }
        }
        do {
            try await KiroProcessTestSupport.waitForFile(fixtureReadyFile)
        } catch {
            runnerTask.cancel()
            _ = try? await runnerTask.value
            throw error
        }
        try KiroProcessTestSupport.touch(beginOutputFile)
        let result = try await runnerTask.value
        try await KiroProcessTestSupport.waitForCondition("settle-exit holder discovery to reach the gate") {
            discoveryStarted.isCompleted()
        }
        let holderPID = try await KiroProcessTestSupport.waitForPID(in: holderPIDFile)
        #expect(kill(holderPID, 0) == 0)
        releaseDiscovery.signal()

        #expect(result.completion == .processExited(status: 0))
        #expect(FileManager.default.fileExists(atPath: rootExitedFile.path))
        let snapshot = try KiroStatusProbe().parse(output: result.text)
        #expect(snapshot.planName == "KIRO FREE")
        #expect(snapshot.creditsUsed == 12.50)
        try await KiroProcessTestSupport.waitForExit(
            of: holderPID,
            timeout: .seconds(20),
            description: "the delayed settle PTY holder to exit")
        #expect(kill(holderPID, 0) == -1)
    }

    private func makeHardStopCLI() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-kiro-cli-\(UUID().uuidString)", isDirectory: true)
        let cliURL = root.appendingPathComponent("kiro-cli")
        let script = """
        #!/usr/bin/python3 -S
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
        with open(sys.argv[6], "w"):
            pass
        while not os.path.exists(sys.argv[7]):
            time.sleep(0.01)
        # Publish the complete frame in one write before the runner's idle deadline starts.
        os.write(1, (
            "Estimated Usage | resets on 2026-06-01 | KIRO FREE\\n"
            "Credits (12.50 of 50 covered in plan)\\n"
            "https://example.com/idle-stop-ready\\n"
            "████████████████████ 25%\\n"
        ).encode())
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
        #!/usr/bin/python3 -S
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
        with open(sys.argv[4], "w"):
            pass
        while not os.path.exists(sys.argv[5]):
            time.sleep(0.01)
        print("Estimated Usage | resets on 2026-06-01 | KIRO FREE", flush=True)
        print("Credits (12.50 of 50 covered in plan)", flush=True)
        print("https://example.com/idle-stop-ready", flush=True)
        while not os.path.exists(sys.argv[2]):
            time.sleep(0.01)
        with open(sys.argv[3], "w") as handle:
            handle.write(str(os.getpid()))
        os._exit(0)
        """
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try script.write(to: cliURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliURL.path)
        return cliURL
    }
}
#endif
