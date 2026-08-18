import Darwin
import Foundation
import Testing
@testable import CodexBar

struct KiroLoginRunnerTests {
    @Test
    func `login runner returns timeout before hung kiro-cli exits`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-kiro-login-runner-\(UUID().uuidString)", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let kiroCLI = binDir.appendingPathComponent("kiro-cli")
        let script = """
        #!/usr/bin/python3
        import time

        print("login-started", flush=True)
        time.sleep(5)
        print("login-finished", flush=True)
        """
        try script.write(to: kiroCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: kiroCLI.path)

        let start = Date()
        let result = await KiroLoginRunner.run(
            timeout: 0.2,
            environment: ["PATH": binDir.path],
            loginPATH: nil)
        let elapsed = Date().timeIntervalSince(start)

        #expect(result.outcome == .timedOut)
        #expect(result.output.contains("login-finished") == false)
        #expect(elapsed < 2.0, "Timeout should return promptly, took \(elapsed)s")
    }

    @Test
    func `login runner bounds output drain when detached child keeps pipes open`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-kiro-login-drain-\(UUID().uuidString)", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let childPIDFile = root.appendingPathComponent("child.pid")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer {
            if let text = try? String(contentsOf: childPIDFile, encoding: .utf8),
               let childPID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                _ = kill(childPID, SIGKILL)
            }
        }

        let kiroCLI = binDir.appendingPathComponent("kiro-cli")
        let script = """
        #!/bin/sh
        /bin/sh -c 'trap "" TERM; /bin/sleep 20' &
        child_pid=$!
        printf '%s\\n' "$child_pid" > "$CODEXBAR_TEST_CHILD_PID_FILE"
        printf 'login-started\\n'
        /bin/sleep 20
        """
        try script.write(to: kiroCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: kiroCLI.path)

        let start = Date()
        let result = await KiroLoginRunner.run(
            timeout: 5,
            outputDrainTimeout: 0.5,
            environment: [
                "CODEXBAR_TEST_CHILD_PID_FILE": childPIDFile.path,
                "PATH": binDir.path,
            ],
            loginPATH: nil)
        let elapsed = Date().timeIntervalSince(start)

        #expect(result.outcome == .timedOut)
        #expect(result.output.contains("login-started"))
        #expect(elapsed < 8.0, "Output drain should stay bounded, took \(elapsed)s")
    }

    @Test
    func `login runner reports progress once a device-flow URL appears`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-kiro-login-progress-\(UUID().uuidString)", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let kiroCLI = binDir.appendingPathComponent("kiro-cli")
        let script = """
        #!/bin/sh
        printf 'Open https://example.com/device?code=ABCD to continue\\n'
        /bin/sleep 1.2
        """
        try script.write(to: kiroCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: kiroCLI.path)

        let progress = ProgressBox()
        let result = await KiroLoginRunner.run(
            timeout: 5,
            environment: ["PATH": binDir.path],
            loginPATH: nil,
            onProgress: { text in progress.record(text) })

        #expect(result.outcome == .success)
        #expect(progress.value?.contains("https://example.com/device?code=ABCD") == true)
    }

    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var text: String?

        var value: String? {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.text
        }

        func record(_ text: String) {
            self.lock.lock()
            self.text = text
            self.lock.unlock()
        }
    }
}
