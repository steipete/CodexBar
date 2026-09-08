import Darwin
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
struct CLILoginRunnerTests {
    @Test(arguments: [false, true])
    func `cancelling a provider login stops its process`(kiro: Bool) async throws {
        let fixture = try Fixture(script: """
        #!/bin/sh
        printf '%s' "$$" > "$LOGIN_PID_FILE"
        printf 'login-started\\n'
        exec /bin/sleep 20
        """, binaryName: kiro ? "kiro-cli" : "codex")
        defer { fixture.remove() }
        let task = Task {
            if kiro {
                return await KiroLoginRunner.run(
                    timeout: 10, environment: fixture.environment, loginPATH: nil)
            }
            return await CodexLoginRunner.run(
                homePath: fixture.root.path, timeout: 10, environment: fixture.environment, loginPATH: nil)
        }
        defer { task.cancel() }
        let pid = try await fixture.waitForPID()
        let start = Date()
        task.cancel()
        let result = await task.value
        #expect(result.outcome == .cancelled)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(CodexLoginAlertPresentation.alertInfo(for: result) == nil)
        #expect(KiroLoginAlertPresentation.alertInfo(for: result) == nil)
    }

    @Test
    func `already cancelled login never launches the executable`() async throws {
        let fixture = try Fixture(script: "#!/bin/sh\nprintf '%s' \"$$\" > \"$LOGIN_PID_FILE\"\n")
        defer { fixture.remove() }
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await fixture.run()
        }.value
        #expect(result.outcome == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: fixture.pidFile.path))
    }

    @Test(arguments: [0, 7])
    func `completed login preserves status and both output streams`(exitCode: Int) async throws {
        let fixture = try Fixture(script: """
        #!/bin/sh
        printf 'stdout-message'
        printf 'stderr-message' >&2
        exit \(exitCode)
        """)
        defer { fixture.remove() }
        let result = await fixture.run()
        #expect(result.outcome == (exitCode == 0 ? .success : .failed(status: Int32(exitCode))))
        #expect(result.output == "stdout-message\nstderr-message")
    }

    @Test
    func `Codex login retains its requested home and login argument`() async throws {
        let fixture = try Fixture(
            script: "#!/bin/sh\nprintf '%s\\n%s' \"$CODEX_HOME\" \"$1\"\n", binaryName: "codex")
        defer { fixture.remove() }
        let result = await CodexLoginRunner.run(
            homePath: fixture.root.path,
            environment: fixture.environment,
            loginPATH: nil)
        #expect(result.outcome == .success)
        #expect(result.output == "\(fixture.root.path)\nlogin")
    }

    @Test(arguments: [Double.infinity, Double.greatestFiniteMagnitude])
    func `large login timeouts do not trap`(timeout: Double) async throws {
        let fixture = try Fixture(script: "#!/bin/sh\nprintf 'done'\n")
        defer { fixture.remove() }
        let result = await fixture.run(timeout: timeout, outputDrainTimeout: timeout)
        #expect(result.outcome == .success)
        #expect(result.output == "done")
    }

    @Test
    func `timeout removes a child that ignores termination`() async throws {
        let fixture = try Fixture(script: """
        #!/bin/sh
        /bin/sh -c 'trap "" TERM; while :; do /bin/sleep 1; done' &
        printf '%s' "$!" > "$LOGIN_PID_FILE"
        printf 'login-started\\n'
        wait
        """)
        defer { fixture.remove() }
        let task = Task { await fixture.run(timeout: 5) }
        let childPID = try await fixture.waitForPID()
        let result = await task.value
        #expect(result.outcome == .timedOut)
        #expect(result.output.contains("login-started"))
        // A reparented child can briefly remain a zombie until launchd reaps it.
        let deadline = Date().addingTimeInterval(2)
        while kill(childPID, 0) == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(kill(childPID, 0) == -1 && errno == ESRCH)
    }

    private struct Fixture: Sendable {
        let root: URL
        let executable: URL
        let pidFile: URL

        var environment: [String: String] {
            ["PATH": self.root.path, "LOGIN_PID_FILE": self.pidFile.path]
        }

        init(script: String, binaryName: String = "login-fixture") throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent("codexbar-cli-login-\(UUID().uuidString)", isDirectory: true)
            self.executable = self.root.appendingPathComponent(binaryName)
            self.pidFile = self.root.appendingPathComponent("login.pid")
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            try script.write(to: self.executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: self.executable.path)
        }

        func run(timeout: TimeInterval = 5, outputDrainTimeout: TimeInterval = 0.5) async -> CLILoginRunner.Result {
            await CLILoginRunner.run(
                executable: self.executable.path,
                environment: self.environment,
                timeout: timeout,
                outputDrainTimeout: outputDrainTimeout)
        }

        func waitForPID() async throws -> pid_t {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if let text = try? String(contentsOf: self.pidFile, encoding: .utf8), let pid = pid_t(text) {
                    return pid
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw CocoaError(.fileReadUnknown)
        }

        func remove() {
            if let text = try? String(contentsOf: self.pidFile, encoding: .utf8), let pid = pid_t(text) {
                kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: self.root)
        }
    }
}
