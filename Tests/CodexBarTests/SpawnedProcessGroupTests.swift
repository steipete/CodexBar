import Foundation
import Testing
@testable import CodexBarCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct SpawnedProcessGroupTests {
    @Test
    func `pipe cleanup preserves standard descriptors`() {
        let descriptors = SpawnedProcessGroup.pipeDescriptorsToClose([0, 1, 2, 3, 4, 3])

        #expect(descriptors == [3, 4])
    }

    #if canImport(Darwin)
    @Test
    func `Darwin device identifier preserves signed bit pattern`() {
        #expect(SpawnedProcessGroup.darwinDeviceIdentifier(-805_306_367) == 3_489_660_929)
    }
    #endif

    @Test
    func `musl close-from selects numeric descriptors at or above minimum`() throws {
        let descriptors = try PosixSpawnFileActionsCloseFrom.descriptorsToClose(startingAt: 4) { path in
            #expect(path == "/proc/self/fd")
            return ["8", "cwd", "3", "4"]
        }

        #expect(descriptors == [4, 8])
    }

    @Test
    func `musl close-from fails when descriptor enumeration fails`() {
        #expect(throws: PosixSpawnFileActionsCloseFrom.CloseFromError.self) {
            try PosixSpawnFileActionsCloseFrom.descriptorsToClose(startingAt: 3) { _ in
                throw CocoaError(.fileReadNoPermission)
            }
        }
    }

    @Test
    func `launch captures child output`() async throws {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutCapture = ProcessPipeCapture(pipe: stdoutPipe)
        let stderrCapture = ProcessPipeCapture(pipe: stderrPipe)
        stdoutCapture.start()
        stderrCapture.start()

        let process = try SpawnedProcessGroup.launch(
            binary: "/bin/sh",
            arguments: ["-c", "printf stdout-value; printf stderr-value >&2"],
            environment: ProcessInfo.processInfo.environment,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe)
        while process.isRunning {
            try await Task.sleep(for: .milliseconds(20))
        }
        await process.terminateResidualProcesses()
        await process.finish()

        async let stdout = stdoutCapture.finish(timeout: .seconds(1))
        async let stderr = stderrCapture.finish(timeout: .seconds(1))
        let output = await (stdout, stderr)

        #expect(process.terminationStatus == 0)
        #expect(String(data: output.0, encoding: .utf8) == "stdout-value")
        #expect(String(data: output.1, encoding: .utf8) == "stderr-value")
    }

    @Test
    func `launch clears the parent thread signal mask`() throws {
        var blockedMask = sigset_t()
        var previousMask = sigset_t()
        sigemptyset(&blockedMask)
        sigaddset(&blockedMask, SIGTERM)
        try #require(pthread_sigmask(SIG_BLOCK, &blockedMask, &previousMask) == 0)
        defer { pthread_sigmask(SIG_SETMASK, &previousMask, nil) }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let script = """
        import signal
        import sys

        blocked = signal.pthread_sigmask(signal.SIG_BLOCK, set())
        sys.exit(1 if signal.SIGTERM in blocked else 0)
        """
        let process = try SpawnedProcessGroup.launch(
            binary: "/usr/bin/python3",
            arguments: ["-c", script],
            environment: ProcessInfo.processInfo.environment,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe)

        while process.isRunning {
            usleep(20000)
        }
        process.finishSynchronously()

        #expect(process.terminationStatus == 0)
    }

    @Test
    func `PTY launch clears the parent thread signal mask`() throws {
        var blockedMask = sigset_t()
        var previousMask = sigset_t()
        sigemptyset(&blockedMask)
        sigaddset(&blockedMask, SIGTERM)
        try #require(pthread_sigmask(SIG_BLOCK, &blockedMask, &previousMask) == 0)
        defer { pthread_sigmask(SIG_SETMASK, &previousMask, nil) }

        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        try #require(openpty(&primaryFD, &secondaryFD, nil, nil, nil) == 0)
        let primaryHandle = FileHandle(fileDescriptor: primaryFD, closeOnDealloc: true)
        let secondaryHandle = FileHandle(fileDescriptor: secondaryFD, closeOnDealloc: true)
        defer {
            try? primaryHandle.close()
            try? secondaryHandle.close()
        }

        let script = """
        import signal
        import sys

        blocked = signal.pthread_sigmask(signal.SIG_BLOCK, set())
        sys.exit(1 if signal.SIGTERM in blocked else 0)
        """
        let process = try SpawnedProcessGroup.launchPTY(
            binary: "/usr/bin/python3",
            arguments: ["-c", script],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: nil,
            fileDescriptors: (primary: primaryFD, secondary: secondaryFD))
        try? secondaryHandle.close()

        while process.isRunning {
            usleep(20000)
        }
        process.finishSynchronously()

        #expect(process.terminationStatus == 0)
    }

    @Test
    func `launch closes unrelated parent descriptors`() async throws {
        let sourceFD = open("/dev/null", O_RDONLY)
        let inheritedFD = fcntl(sourceFD, F_DUPFD, 200)
        close(sourceFD)
        let resolvedFD = try #require(inheritedFD >= 200 ? inheritedFD : nil)
        defer { close(resolvedFD) }
        _ = fcntl(resolvedFD, F_SETFD, 0)

        #if canImport(Darwin)
        let descriptorPath = "/dev/fd/\(resolvedFD)"
        #else
        let descriptorPath = "/proc/self/fd/\(resolvedFD)"
        #endif
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = try SpawnedProcessGroup.launch(
            binary: "/bin/sh",
            arguments: ["-c", "test ! -e \(descriptorPath)"],
            environment: ProcessInfo.processInfo.environment,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe)

        while process.isRunning {
            try await Task.sleep(for: .milliseconds(20))
        }
        await process.terminateResidualProcesses()
        await process.finish()

        #expect(process.terminationStatus == 0)
    }

    @Test
    func `termination waits for grace before killing escaped descendants`() async throws {
        let childPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-process-group-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: childPIDFile) }

        let script = """
        import subprocess
        import sys
        import time

        child = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import os,signal,sys,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                "open(sys.argv[1], 'w').write(str(os.getpid())); time.sleep(30)",
                sys.argv[1],
            ],
            start_new_session=True,
        )
        time.sleep(30)
        """
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = try SpawnedProcessGroup.launch(
            binary: "/usr/bin/python3",
            arguments: ["-c", script, childPIDFile.path],
            environment: ProcessInfo.processInfo.environment,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe)

        var childPID: pid_t?
        for _ in 0..<500 {
            if let text = try? String(contentsOf: childPIDFile, encoding: .utf8),
               let parsedPID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                childPID = parsedPID
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let escapedPID = childPID else {
            await process.terminate(grace: 0)
            Issue.record("Timed out waiting for escaped child PID")
            return
        }
        defer { _ = kill(escapedPID, SIGKILL) }

        let start = Date()
        await process.terminate(grace: 0.3)
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed >= 0.25, "Termination should honor the grace period before SIGKILL")
        #expect(kill(escapedPID, 0) == -1)
    }

    @Test
    func `termination kills reparented process group members after root exit`() async throws {
        let childPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-process-group-member-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: childPIDFile) }

        let script = """
        import os
        import signal
        import sys
        import time

        intermediate = os.fork()
        if intermediate == 0:
            child = os.fork()
            if child > 0:
                os._exit(0)
            os.close(1)
            os.close(2)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            with open(sys.argv[1], "w") as handle:
                handle.write(str(os.getpid()))
            time.sleep(30)
            os._exit(0)

        os.waitpid(intermediate, 0)
        time.sleep(30)
        """
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = try SpawnedProcessGroup.launch(
            binary: "/usr/bin/python3",
            arguments: ["-c", script, childPIDFile.path],
            environment: ProcessInfo.processInfo.environment,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe)

        var childPID: pid_t?
        for _ in 0..<100 {
            if let text = try? String(contentsOf: childPIDFile, encoding: .utf8),
               let parsedPID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                childPID = parsedPID
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let reparentedPID = try #require(childPID)
        defer { _ = kill(reparentedPID, SIGKILL) }

        await process.terminate(grace: 0.2)

        #expect(kill(reparentedPID, 0) == -1)
    }

    @Test
    func `termination gives reparented process group members grace`() async throws {
        let childPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-process-group-grace-\(UUID().uuidString).pid")
        let termReceivedFile = childPIDFile.appendingPathExtension("term")
        let gracefulExitFile = childPIDFile.appendingPathExtension("graceful")
        defer {
            try? FileManager.default.removeItem(at: childPIDFile)
            try? FileManager.default.removeItem(at: termReceivedFile)
            try? FileManager.default.removeItem(at: gracefulExitFile)
        }

        let script = """
        import os
        import signal
        import sys
        import time

        intermediate = os.fork()
        if intermediate == 0:
            child = os.fork()
            if child > 0:
                os._exit(0)
            os.close(1)
            os.close(2)
            def handle_term(_signal, _frame):
                with open(sys.argv[2], "w") as handle:
                    handle.write("term")
                time.sleep(0.1)
                with open(sys.argv[3], "w") as handle:
                    handle.write("graceful")
                os._exit(0)
            signal.signal(signal.SIGTERM, handle_term)
            signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM})
            with open(sys.argv[1], "w") as handle:
                handle.write(str(os.getpid()))
            time.sleep(30)
            os._exit(0)

        os.waitpid(intermediate, 0)
        time.sleep(30)
        """
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = try SpawnedProcessGroup.launch(
            binary: "/usr/bin/python3",
            arguments: ["-c", script, childPIDFile.path, termReceivedFile.path, gracefulExitFile.path],
            environment: ProcessInfo.processInfo.environment,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe)

        var childPID: pid_t?
        for _ in 0..<100 {
            if let text = try? String(contentsOf: childPIDFile, encoding: .utf8),
               let parsedPID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                childPID = parsedPID
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let reparentedPID = try #require(childPID)
        defer { _ = kill(reparentedPID, SIGKILL) }
        for _ in 0..<100
            where TTYProcessTreeTerminator.descendantPIDs(of: process.pid).contains(reparentedPID)
        {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!TTYProcessTreeTerminator.descendantPIDs(of: process.pid).contains(reparentedPID))
        #expect(getpgid(reparentedPID) == process.processGroup)

        await process.terminate(grace: 0.3)

        #expect(FileManager.default.fileExists(atPath: termReceivedFile.path))
        #expect(FileManager.default.fileExists(atPath: gracefulExitFile.path))
        #expect(kill(reparentedPID, 0) == -1)
    }

    @Test
    func `residual termination cleans same group helpers spawned during SIGTERM`() async throws {
        let readyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-process-group-term-\(UUID().uuidString).ready")
        let childPIDFile = readyFile.appendingPathExtension("pid")
        let heartbeatFile = readyFile.appendingPathExtension("heartbeat")
        defer {
            try? FileManager.default.removeItem(at: readyFile)
            try? FileManager.default.removeItem(at: childPIDFile)
            try? FileManager.default.removeItem(at: heartbeatFile)
        }

        let script = """
        import os
        import signal
        import sys
        import time

        def handle_term(_signal, _frame):
            reader, writer = os.pipe()
            child = os.fork()
            if child == 0:
                os.close(reader)
                os.close(1)
                os.close(2)
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                with open(sys.argv[2], "w") as handle:
                    handle.write(str(os.getpid()))
                with open(sys.argv[3], "w") as heartbeat:
                    heartbeat.write("1")
                    heartbeat.flush()
                    os.write(writer, b"1")
                    os.close(writer)
                    counter = 1
                    while True:
                        counter += 1
                        heartbeat.seek(0)
                        heartbeat.write(str(counter))
                        heartbeat.truncate()
                        heartbeat.flush()
                        time.sleep(0.02)
            os.close(writer)
            os.read(reader, 1)
            os.close(reader)
            os._exit(0)

        signal.signal(signal.SIGTERM, handle_term)
        signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM})
        with open(sys.argv[1], "w") as handle:
            handle.write("ready")
        time.sleep(30)
        """
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = try SpawnedProcessGroup.launch(
            binary: "/usr/bin/python3",
            arguments: ["-c", script, readyFile.path, childPIDFile.path, heartbeatFile.path],
            environment: ProcessInfo.processInfo.environment,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe)

        for _ in 0..<100 where !FileManager.default.fileExists(atPath: readyFile.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: readyFile.path))

        await process.terminateResidualProcesses(grace: 0.2)
        await process.finish()

        var childPID: pid_t?
        for _ in 0..<100 {
            if let text = try? String(contentsOf: childPIDFile, encoding: .utf8),
               let parsedPID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                childPID = parsedPID
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let resolvedChildPID = try #require(childPID)
        defer { _ = kill(resolvedChildPID, SIGKILL) }
        let heartbeatAfterCleanup = try String(contentsOf: heartbeatFile, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(200))
        let heartbeatAfterSettle = try String(contentsOf: heartbeatFile, encoding: .utf8)
        #expect(heartbeatAfterSettle == heartbeatAfterCleanup)
    }

    @Test
    func `normal exit cleans a session escaped output holder`() async throws {
        let childPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-process-holder-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: childPIDFile) }

        let script = """
        import subprocess
        import sys

        child = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)",
            ],
            start_new_session=True,
        )
        with open(sys.argv[1], "w") as handle:
            handle.write(str(child.pid))
        print("parent complete", flush=True)
        """
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = try SpawnedProcessGroup.launch(
            binary: "/usr/bin/python3",
            arguments: ["-c", script, childPIDFile.path],
            environment: ProcessInfo.processInfo.environment,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe)

        while process.isRunning {
            try await Task.sleep(for: .milliseconds(20))
        }
        var childPID: pid_t?
        for _ in 0..<100 {
            if let text = try? String(contentsOf: childPIDFile, encoding: .utf8),
               let parsedPID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                childPID = parsedPID
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let resolvedChildPID = try #require(childPID)
        defer { _ = kill(resolvedChildPID, SIGKILL) }
        #expect(kill(resolvedChildPID, 0) == 0)

        await process.terminateResidualProcesses(grace: 0.2)
        await process.finish()

        #expect(kill(resolvedChildPID, 0) == -1)
    }

    @Test
    func `normal exit cleans a same group helper without output pipes`() async throws {
        let childPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-process-group-holder-\(UUID().uuidString).pid")
        let heartbeatFile = childPIDFile.appendingPathExtension("heartbeat")
        defer {
            try? FileManager.default.removeItem(at: childPIDFile)
            try? FileManager.default.removeItem(at: heartbeatFile)
        }

        let script = """
        import os
        import signal
        import sys
        import time

        child = os.fork()
        if child == 0:
            os.close(1)
            os.close(2)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            with open(sys.argv[1], "w") as handle:
                handle.write(str(os.getpid()))
            counter = 0
            with open(sys.argv[2], "w") as heartbeat:
                while True:
                    counter += 1
                    heartbeat.seek(0)
                    heartbeat.write(str(counter))
                    heartbeat.truncate()
                    heartbeat.flush()
                    time.sleep(0.02)
            os._exit(0)
        """
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = try SpawnedProcessGroup.launch(
            binary: "/usr/bin/python3",
            arguments: ["-c", script, childPIDFile.path, heartbeatFile.path],
            environment: ProcessInfo.processInfo.environment,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe)

        while process.isRunning {
            try await Task.sleep(for: .milliseconds(20))
        }
        var childPID: pid_t?
        for _ in 0..<100 {
            if let text = try? String(contentsOf: childPIDFile, encoding: .utf8),
               let parsedPID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                childPID = parsedPID
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let resolvedChildPID = try #require(childPID)
        defer { _ = kill(resolvedChildPID, SIGKILL) }
        #expect(getpgid(resolvedChildPID) == process.processGroup)
        #expect(kill(resolvedChildPID, 0) == 0)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: heartbeatFile.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let heartbeatBefore = try String(contentsOf: heartbeatFile, encoding: .utf8)
        var heartbeatWhileRunning = heartbeatBefore
        for _ in 0..<100 where heartbeatWhileRunning == heartbeatBefore {
            try await Task.sleep(for: .milliseconds(20))
            heartbeatWhileRunning = try String(contentsOf: heartbeatFile, encoding: .utf8)
        }
        #expect(heartbeatWhileRunning != heartbeatBefore)

        await process.terminateResidualProcesses(grace: 0.2)
        await process.finish()

        try await Task.sleep(for: .milliseconds(100))
        let heartbeatAfterCleanup = try String(contentsOf: heartbeatFile, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(200))
        let heartbeatAfterSettle = try String(contentsOf: heartbeatFile, encoding: .utf8)
        #expect(heartbeatAfterSettle == heartbeatAfterCleanup)
    }

    @Test
    func `normal exit cleanup catches helper spawned during SIGTERM`() async throws {
        let readyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-process-group-post-exit-\(UUID().uuidString).ready")
        let childPIDFile = readyFile.appendingPathExtension("pid")
        let heartbeatFile = readyFile.appendingPathExtension("heartbeat")
        defer {
            try? FileManager.default.removeItem(at: readyFile)
            try? FileManager.default.removeItem(at: childPIDFile)
            try? FileManager.default.removeItem(at: heartbeatFile)
        }

        let script = """
        import os
        import signal
        import sys
        import time

        helper = os.fork()
        if helper == 0:
            os.close(1)
            os.close(2)
            def handle_term(_signal, _frame):
                reader, writer = os.pipe()
                child = os.fork()
                if child == 0:
                    os.close(reader)
                    signal.signal(signal.SIGTERM, signal.SIG_IGN)
                    with open(sys.argv[2], "w") as handle:
                        handle.write(str(os.getpid()))
                    with open(sys.argv[3], "w") as heartbeat:
                        heartbeat.write("1")
                        heartbeat.flush()
                        os.write(writer, b"1")
                        os.close(writer)
                        counter = 1
                        while True:
                            counter += 1
                            heartbeat.seek(0)
                            heartbeat.write(str(counter))
                            heartbeat.truncate()
                            heartbeat.flush()
                            time.sleep(0.02)
                os.close(writer)
                os.read(reader, 1)
                os.close(reader)
                os._exit(0)

            signal.signal(signal.SIGTERM, handle_term)
            signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM})
            with open(sys.argv[1], "w") as handle:
                handle.write("ready")
            time.sleep(30)
            os._exit(0)

        while not os.path.exists(sys.argv[1]):
            time.sleep(0.01)
        os._exit(0)
        """
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = try SpawnedProcessGroup.launch(
            binary: "/usr/bin/python3",
            arguments: ["-c", script, readyFile.path, childPIDFile.path, heartbeatFile.path],
            environment: ProcessInfo.processInfo.environment,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe)

        while process.isRunning {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: readyFile.path))

        await process.terminateResidualProcesses(grace: 0.2)
        await process.finish()

        var childPID: pid_t?
        for _ in 0..<100 {
            if let text = try? String(contentsOf: childPIDFile, encoding: .utf8),
               let parsedPID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                childPID = parsedPID
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let resolvedChildPID = try #require(childPID)
        defer { _ = kill(resolvedChildPID, SIGKILL) }
        let heartbeatAfterCleanup = try String(contentsOf: heartbeatFile, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(200))
        let heartbeatAfterSettle = try String(contentsOf: heartbeatFile, encoding: .utf8)
        #expect(heartbeatAfterSettle == heartbeatAfterCleanup)
    }
}
