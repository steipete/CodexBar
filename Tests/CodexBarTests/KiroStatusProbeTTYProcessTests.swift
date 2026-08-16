import Foundation
import Testing
@testable import CodexBarCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

extension KiroStatusProbeTests {
    @Test
    func `tty runner hard stops a process that ignores SIGTERM`() async throws {
        let readyFile = Self.temporaryMarker("hard-stop-ready")
        let startFile = Self.temporaryMarker("hard-stop-start")
        let cliURL = try self.makeTTYCLI(
            """
            #!/bin/sh
            : > "$1"
            while [ ! -e "$2" ]; do sleep 0.01; done
            trap '' TERM
            printf 'https://example.com/partial-output\n'
            while true; do sleep 1; done
            """)
        defer { self.removeTTYFixture(cliURL: cliURL, files: [readyFile, startFile]) }

        let result = try await KiroProcessTestSupport.runTTYAfterFixtureReady(
            binary: cliURL,
            readyFile: readyFile,
            startFile: startFile,
            options: .init(
                timeout: 30,
                idleTimeout: 0.1,
                extraArgs: [readyFile.path, startFile.path]))

        #expect(result.completion == .idleTimeout)
        #expect(result.text.contains("partial-output"))
    }

    @Test
    func `tty runner kills a pipe holder that escapes the process group`() async throws {
        let childPIDFile = Self.temporaryMarker("escaped", pathExtension: "pid")
        let readyFile = Self.temporaryMarker("escaped-ready")
        let startFile = Self.temporaryMarker("escaped-start")
        let cliURL = try self.makeTTYCLI(
            """
            #!/usr/bin/python3
            import os
            import subprocess
            import sys
            import time

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
            with open(sys.argv[2], "w"):
                pass
            while not os.path.exists(sys.argv[3]):
                time.sleep(0.01)
            print("partial output", flush=True)
            time.sleep(30)
            """)
        defer { self.removeTTYFixture(cliURL: cliURL, files: [childPIDFile, readyFile, startFile]) }

        let result = try await KiroProcessTestSupport.runTTYAfterFixtureReady(
            binary: cliURL,
            readyFile: readyFile,
            startFile: startFile,
            options: .init(
                timeout: 30,
                idleTimeout: 0.1,
                extraArgs: [childPIDFile.path, readyFile.path, startFile.path]))

        #expect(result.completion == .idleTimeout)
        #expect(result.text.contains("partial output"))

        let childPID = try await KiroProcessTestSupport.waitForPID(in: childPIDFile)
        defer { _ = kill(childPID, SIGKILL) }
        try await KiroProcessTestSupport.waitForExit(
            of: childPID,
            timeout: .seconds(20),
            description: "the escaped PTY output holder to exit")
        #expect(kill(childPID, 0) == -1)
    }

    @Test
    func `tty runner cleans a same group helper after normal exit`() async throws {
        let childPIDFile = Self.temporaryMarker("normal-exit", pathExtension: "pid")
        let readyFile = Self.temporaryMarker("normal-exit-ready")
        let startFile = Self.temporaryMarker("normal-exit-start")
        let cliURL = try self.makeTTYCLI(
            """
            #!/usr/bin/python3
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
                time.sleep(30)
                os._exit(0)

            while not os.path.exists(sys.argv[1]):
                time.sleep(0.01)
            with open(sys.argv[2], "w"):
                pass
            while not os.path.exists(sys.argv[3]):
                time.sleep(0.01)
            print("parent complete", flush=True)
            os._exit(0)
            """)
        defer { self.removeTTYFixture(cliURL: cliURL, files: [childPIDFile, readyFile, startFile]) }

        let result = try await KiroProcessTestSupport.runTTYAfterFixtureReady(
            binary: cliURL,
            readyFile: readyFile,
            startFile: startFile,
            options: .init(
                timeout: 30,
                extraArgs: [childPIDFile.path, readyFile.path, startFile.path]))

        #expect(result.completion == .processExited(status: 0))
        #expect(result.text.contains("parent complete"))

        let childPID = try await KiroProcessTestSupport.waitForPID(in: childPIDFile)
        defer { _ = kill(childPID, SIGKILL) }
        try await KiroProcessTestSupport.waitForExit(
            of: childPID,
            timeout: .seconds(20),
            description: "the same-group PTY helper to exit")
        #expect(kill(childPID, 0) == -1)
    }

    @Test
    func `tty runner preserves completed no-output failure status`() async throws {
        let readyFile = Self.temporaryMarker("empty-exit-ready")
        let startFile = Self.temporaryMarker("empty-exit-start")
        let cliURL = try self.makeTTYCLI(
            """
            #!/bin/sh
            : > "$1"
            while [ ! -e "$2" ]; do sleep 0.01; done
            exit 23
            """)
        defer { self.removeTTYFixture(cliURL: cliURL, files: [readyFile, startFile]) }

        let result = try await KiroProcessTestSupport.runTTYAfterFixtureReady(
            binary: cliURL,
            readyFile: readyFile,
            startFile: startFile,
            options: .init(
                timeout: 30,
                extraArgs: [readyFile.path, startFile.path],
                returnOnEmptyProcessExit: true))

        #expect(result.text.isEmpty)
        #expect(result.completion == .processExited(status: 23))
    }

    @Test
    func `tty runner cancellation terminates the process`() async throws {
        let pidFile = Self.temporaryMarker("cancel", pathExtension: "pid")
        let cliURL = try self.makeTTYCLI(
            """
            #!/bin/sh
            printf '%s\n' "$$" > "$1"
            trap '' TERM
            while true; do sleep 1; done
            """)
        defer { self.removeTTYFixture(cliURL: cliURL, files: [pidFile]) }

        let task = Task {
            try TTYCommandRunner().run(
                binary: cliURL.path,
                send: "",
                options: .init(timeout: 30, extraArgs: [pidFile.path]))
        }
        defer { task.cancel() }

        let processID = try await KiroProcessTestSupport.waitForPID(in: pidFile)
        defer { _ = kill(processID, SIGKILL) }

        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(kill(processID, 0) == -1)
    }

    private static func temporaryMarker(_ name: String, pathExtension: String = "started") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-kiro-\(name)-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
    }

    private func makeTTYCLI(_ script: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-kiro-tty-\(UUID().uuidString)", isDirectory: true)
        let cliURL = root.appendingPathComponent("kiro-cli")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try script.write(to: cliURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliURL.path)
        return cliURL
    }

    private func removeTTYFixture(cliURL: URL, files: [URL]) {
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
        try? FileManager.default.removeItem(at: cliURL.deletingLastPathComponent())
    }
}
