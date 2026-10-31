#if canImport(Darwin)
import Darwin
import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeWatchdogTests {
    static func buildWatchdogExecutable(in directory: URL) async throws -> URL {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repoRoot.appendingPathComponent("Sources/CodexBarClaudeWatchdog/main.swift")
        let outputURL = directory.appendingPathComponent("CodexBarClaudeWatchdog")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", sourceURL.path, "-o", outputURL.path]
        try compiler.run()
        defer { if compiler.isRunning { compiler.terminate() } }
        try await Self.waitForExit(compiler, timeout: 60)
        try #require(compiler.terminationStatus == 0)
        return outputURL
    }

    static func waitForExit(_ process: Process, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!process.isRunning, "Synthetic process did not exit before the deadline")
    }

    @Test
    func `watchdog isolates child process group at spawn and preserves caller group during teardown`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-watchdog-pgid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let watchdogURL = try await Self.buildWatchdogExecutable(in: directory)
        let pidsFile = directory.appendingPathComponent("pids.txt")
        let childScript = directory.appendingPathComponent("child.sh")
        try """
        #!/bin/sh
        /bin/sleep 30 &
        grandchild=$!
        printf '%s %s\\n' "$$" "$grandchild" > '\(pidsFile.path)'
        wait "$grandchild"
        """.write(to: childScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: childScript.path)

        let harnessFile = directory.appendingPathComponent("harness.txt")
        let harnessScript = directory.appendingPathComponent("harness.sh")
        try """
        #!/bin/sh
        /bin/sleep 30 &
        sibling=$!
        '\(watchdogURL.path)' -- '\(childScript.path)' &
        watchdog=$!
        printf '%s %s\\n' "$sibling" "$watchdog" > '\(harnessFile.path)'
        wait "$watchdog"
        rc=$?
        if kill -0 "$sibling" 2>/dev/null; then
          sibling_alive=1
          kill -9 "$sibling" 2>/dev/null || true
        else
          sibling_alive=0
        fi
        printf '%s %s\\n' "$rc" "$sibling_alive" > '\(directory.appendingPathComponent("result.txt").path)'
        exit "$rc"
        """.write(to: harnessScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harnessScript.path)

        var attr: posix_spawnattr_t?
        #expect(posix_spawnattr_init(&attr) == 0)
        defer { posix_spawnattr_destroy(&attr) }
        #expect(posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK)) == 0)
        #expect(posix_spawnattr_setpgroup(&attr, 0) == 0)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        #expect(posix_spawnattr_setsigmask(&attr, &emptyMask) == 0)

        var harnessPID: pid_t = 0
        let argvStrings = [strdup(harnessScript.path), nil]
        defer { argvStrings.forEach { if let p = $0 { free(p) } } }
        let spawnRC = argvStrings.withUnsafeBufferPointer { buf in
            let mutBuf = UnsafeMutablePointer(mutating: buf.baseAddress)
            return posix_spawn(&harnessPID, harnessScript.path, nil, &attr, mutBuf, environ)
        }
        #expect(spawnRC == 0)
        defer {
            if harnessPID > 0 {
                kill(-harnessPID, SIGKILL)
            }
        }

        let startDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: pidsFile.path) ||
            !FileManager.default.fileExists(atPath: harnessFile.path),
            Date() < startDeadline
        {
            try await Task.sleep(for: .milliseconds(25))
        }

        let harnessParts = try String(contentsOf: harnessFile, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace)
            .compactMap { pid_t($0) }
        let childParts = try String(contentsOf: pidsFile, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace)
            .compactMap { pid_t($0) }
        #expect(harnessParts.count == 2)
        #expect(childParts.count == 2)

        let siblingPID = try #require(harnessParts.first)
        let watchdogPID = try #require(harnessParts.last)
        let childPID = try #require(childParts.first)
        let grandchildPID = try #require(childParts.last)

        let outerGroup = getpgid(watchdogPID)
        let childGroup = getpgid(childPID)
        #expect(outerGroup == harnessPID)
        #expect(getpgid(siblingPID) == outerGroup)
        #expect(childGroup == childPID)
        #expect(childGroup != outerGroup)
        #expect(getpgid(grandchildPID) == childGroup)

        #expect(kill(watchdogPID, SIGTERM) == 0)

        var harnessStatus: Int32 = 0
        let exitDeadline = Date().addingTimeInterval(5)
        var reapedHarness: pid_t = 0
        while Date() < exitDeadline {
            reapedHarness = waitpid(harnessPID, &harnessStatus, WNOHANG)
            if reapedHarness == harnessPID { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(reapedHarness == harnessPID)
        let resultParts = try String(
            contentsOf: directory.appendingPathComponent("result.txt"),
            encoding: .utf8)
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Int32($0) }
        #expect(resultParts == [143, 1])
        #expect(kill(childPID, 0) != 0)
        #expect(kill(grandchildPID, 0) != 0)
    }

    @Test
    func `watchdog preserves child exit status 143 when orphaned by parent exit`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-watchdog-orphan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let watchdogURL = try await Self.buildWatchdogExecutable(in: directory)
        let childReadyFile = directory.appendingPathComponent("ready.txt")
        let watchdogPIDFile = directory.appendingPathComponent("watchdog.pid")
        let parentHoldFile = directory.appendingPathComponent("hold.txt")
        try "hold".write(to: parentHoldFile, atomically: true, encoding: .utf8)

        let childScript = directory.appendingPathComponent("child.sh")
        try """
        #!/bin/sh
        printf '%s\\n' "$$" > '\(childReadyFile.path)'
        exec /bin/sleep 30
        """.write(to: childScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: childScript.path)

        let spawner = Process()
        spawner.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        spawner.arguments = [
            "-c",
            """
            import os, subprocess, sys, time
            p = subprocess.Popen([sys.argv[1], "--", sys.argv[2]])
            open(sys.argv[3], "w").write(str(p.pid))
            deadline = time.time() + 5.0
            while os.path.exists(sys.argv[4]) and time.time() < deadline:
                time.sleep(0.02)
            os._exit(0)
            """,
            watchdogURL.path,
            childScript.path,
            watchdogPIDFile.path,
            parentHoldFile.path,
        ]
        try spawner.run()
        defer { if spawner.isRunning { spawner.terminate() } }

        let startDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: watchdogPIDFile.path) ||
            !FileManager.default.fileExists(atPath: childReadyFile.path),
            Date() < startDeadline
        {
            try await Task.sleep(for: .milliseconds(20))
        }

        let watchdogPID = try #require(
            Int32(String(contentsOf: watchdogPIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let childPID = try #require(
            Int32(String(contentsOf: childReadyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))

        let kq = kqueue()
        #expect(kq >= 0)
        defer { close(kq) }

        var change = kevent(
            ident: UInt(watchdogPID),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT) | UInt32(bitPattern: NOTE_EXITSTATUS),
            data: 0,
            udata: nil)
        #expect(kevent(kq, &change, 1, nil, 0, nil) == 0)

        // Let the intermediate parent exit so the watchdog becomes orphaned (getppid() == 1).
        try? FileManager.default.removeItem(at: parentHoldFile)
        try await Self.waitForExit(spawner)

        var event = kevent()
        var timeout = timespec(tv_sec: 5, tv_nsec: 0)
        let n = kevent(kq, nil, 0, &event, 1, &timeout)
        #expect(n == 1)
        let waitStatus = Int32(truncatingIfNeeded: event.data)
        let orphanExitCode = (waitStatus >> 8) & 0xFF
        #expect(orphanExitCode == 143)

        let deadline = Date().addingTimeInterval(2)
        while kill(childPID, 0) == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(kill(childPID, 0) != 0)
    }

    @Test
    func `watchdog escalation preserves an external group when its child changes groups`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-watchdog-kill-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let watchdogURL = try await Self.buildWatchdogExecutable(in: directory)
        let sentinel = Process()
        sentinel.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sentinel.arguments = ["30"]
        try sentinel.run()
        let sentinelPID = sentinel.processIdentifier
        #expect(setpgid(sentinelPID, sentinelPID) == 0 || getpgid(sentinelPID) == sentinelPID)
        defer {
            if sentinel.isRunning { sentinel.terminate() }
        }

        let readyFile = directory.appendingPathComponent("ready.txt")
        let switchedFile = directory.appendingPathComponent("switched.txt")
        let childScript = directory.appendingPathComponent("child.py")
        try """
        #!/usr/bin/python3
        import os, signal, subprocess, sys, time

        target_pgid = int(sys.argv[1])
        ready_path = sys.argv[2]
        switched_path = sys.argv[3]

        grandchild = subprocess.Popen(["/bin/sleep", "30"])

        def on_term(signum, frame):
            os.setpgid(0, target_pgid)
            with open(switched_path, "w") as f:
                f.write(f"{os.getpid()} {os.getpgrp()}\\n")

        signal.signal(signal.SIGTERM, on_term)
        with open(ready_path, "w") as f:
            f.write(f"{os.getpid()} {os.getpgrp()} {grandchild.pid}\\n")

        deadline = time.time() + 30.0
        while time.time() < deadline:
            time.sleep(0.05)
        """.write(to: childScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: childScript.path)

        let watchdog = Process()
        watchdog.executableURL = watchdogURL
        watchdog.arguments = ["--", childScript.path, "\(sentinelPID)", readyFile.path, switchedFile.path]
        try watchdog.run()
        defer {
            if watchdog.isRunning { watchdog.terminate() }
        }

        let startDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: readyFile.path), Date() < startDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        let readyParts = try String(contentsOf: readyFile, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace)
            .compactMap { pid_t($0) }
        #expect(readyParts.count == 3)
        let childPID = try #require(readyParts.first)
        let initialChildPGID = try #require(readyParts.dropFirst().first)
        let grandchildPID = try #require(readyParts.last)
        #expect(initialChildPGID == childPID)
        #expect(initialChildPGID != sentinelPID)

        #expect(kill(watchdog.processIdentifier, SIGTERM) == 0)
        try await Self.waitForExit(watchdog)
        #expect(watchdog.terminationStatus == 143)

        let switchedParts = try String(contentsOf: switchedFile, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace)
            .compactMap { pid_t($0) }
        #expect(switchedParts == [childPID, sentinelPID])

        let stopDeadline = Date().addingTimeInterval(2)
        while kill(childPID, 0) == 0 || kill(grandchildPID, 0) == 0, Date() < stopDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(kill(childPID, 0) != 0)
        #expect(kill(grandchildPID, 0) != 0)
        #expect(sentinel.isRunning)
        #expect(kill(sentinelPID, 0) == 0)
    }
}
#endif
