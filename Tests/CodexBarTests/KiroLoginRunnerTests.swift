import CodexBarCore
import Darwin
import Foundation
import Testing
@testable import CodexBar

struct KiroLoginRunnerTests {
    @Test(.timeLimit(.minutes(1)))
    func `login runner returns timeout before hung kiro-cli exits`() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("root.pid")
        defer { Self.killFixture(in: pidFile) }
        try Self.installCLI(in: root, script: """
        import os, signal
        print("login-started", flush=True)
        with open(os.environ["FIXTURE_PID"], "w") as handle:
            handle.write(str(os.getpid()))
        signal.pause()
        print("login-finished", flush=True)
        """)
        let fired = LockIsolated(false)
        let defaultSleep = BoundedTaskJoinTiming.sleep
        let fireLoginDeadline: @Sendable (Duration) async throws -> Void = { duration in
            if fired.value {
                return try await defaultSleep(duration)
            }
            fired.setValue(true)
            #expect(duration == .milliseconds(200))
            _ = try await KiroProcessTestSupport.waitForPID(in: pidFile)
        }
        let result = await BoundedTaskJoinTiming.$sleep.withValue(fireLoginDeadline) {
            await KiroLoginRunner.run(
                timeout: 0.2,
                environment: ["PATH": root.path, "FIXTURE_PID": pidFile.path],
                loginPATH: nil)
        }

        #expect(fired.value)
        #expect(result.outcome == .timedOut)
        #expect(result.output.contains("login-started"))
        #expect(!result.output.contains("login-finished"))
        let pid = try #require(KiroProcessTestSupport.readPID(from: pidFile))
        #expect(kill(pid, 0) == -1)
    }

    @Test(.timeLimit(.minutes(1)))
    func `login runner bounds output drain when detached child keeps pipes open`() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let childPIDFile = root.appendingPathComponent("child.pid")
        defer { Self.killFixture(in: childPIDFile) }
        try Self.installCLI(in: root, script: """
        import os, signal
        ready_read, ready_write = os.pipe()
        intermediate = os.fork()
        if intermediate == 0:
            if os.fork() != 0:
                os._exit(0)
            os.setsid()
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            with open(os.environ["FIXTURE_PID"], "w") as handle:
                handle.write(str(os.getpid()))
            os.write(ready_write, b"R")
            \(KiroProcessTestSupport.pythonOwnerBoundedHold())
            os._exit(0)
        os.waitpid(intermediate, 0)
        os.read(ready_read, 1)
        print("login-started", flush=True)
        signal.pause()
        """)
        let result = await KiroLoginRunner.run(
            timeout: 5,
            outputDrainTimeout: 0.05,
            environment: ["PATH": root.path, "FIXTURE_PID": childPIDFile.path],
            loginPATH: nil)

        #expect(result.outcome == .timedOut)
        #expect(result.output.contains("login-started"))
        let childPID = try #require(KiroProcessTestSupport.readPID(from: childPIDFile))
        // The acknowledged writer is still held: returning cannot depend on pipe EOF.
        #expect(kill(childPID, 0) == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func `detached fixture hold exits when its owning process is killed`() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let holderPIDFile = root.appendingPathComponent("holder.pid")
        // Emergency cleanup only: the assertion below requires the holder to exit on its own.
        defer { Self.killFixture(in: holderPIDFile) }
        // The synthetic owner stands in for the test process: it detaches the same SIGTERM-ignoring
        // holder as the output-drain fixture, bound to the owner's PID, and is then SIGKILLed.
        let owner = Process()
        owner.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        owner.arguments = ["-c", """
        import os, signal, sys
        owner = os.getpid()
        intermediate = os.fork()
        if intermediate == 0:
            if os.fork() != 0:
                os._exit(0)
            os.setsid()
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            with open(sys.argv[1], "w") as handle:
                handle.write(str(os.getpid()))
            \(KiroProcessTestSupport.pythonOwnerBoundedHold(ownerPID: "owner"))
            os._exit(0)
        os.waitpid(intermediate, 0)
        \(KiroProcessTestSupport.pythonOwnerBoundedHold())
        """, holderPIDFile.path]
        owner.standardOutput = FileHandle.nullDevice
        owner.standardError = FileHandle.nullDevice
        try owner.run()
        defer {
            if owner.isRunning { _ = kill(owner.processIdentifier, SIGKILL) }
            ProcessExitRelease.afterExit(owner)
        }

        let holderPID = try await KiroProcessTestSupport.waitForPID(in: holderPIDFile)
        #expect(kill(holderPID, 0) == 0)
        #expect(kill(owner.processIdentifier, SIGKILL) == 0)

        try await KiroProcessTestSupport.waitForExit(
            of: holderPID,
            timeout: .seconds(10),
            description: "detached holder exit after its owner was SIGKILLed")
    }

    @Test(.timeLimit(.minutes(1)))
    func `login runner reports progress once a device-flow URL appears`() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let releasePath = root.appendingPathComponent("release").path
        try #require(mkfifo(releasePath, 0o600) == 0)
        let descriptor = open(releasePath, O_RDWR | O_CLOEXEC)
        try #require(descriptor >= 0)
        let release = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? release.close() }
        try Self.installCLI(in: root, script: """
        import os
        print("Open https://example.com/device?code=ABCD to continue", flush=True)
        with open(os.environ["FIXTURE_RELEASE"], "rb") as handle:
            handle.read(1)
        """)
        let result = await KiroLoginRunner.run(
            timeout: 30,
            environment: ["PATH": root.path, "FIXTURE_RELEASE": releasePath],
            loginPATH: nil,
            onProgress: { text in
                #expect(text.contains("https://example.com/device?code=ABCD"))
                try? release.write(contentsOf: Data([1]))
            })

        #expect(result.outcome == .success)
    }

    private static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-kiro-login-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func installCLI(in root: URL, script: String) throws {
        let cli = root.appendingPathComponent("kiro-cli")
        try ("#!/usr/bin/python3\n" + script).write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
    }

    private static func killFixture(in file: URL) {
        if let pid = KiroProcessTestSupport.readPID(from: file) { _ = kill(pid, SIGKILL) }
    }
}
