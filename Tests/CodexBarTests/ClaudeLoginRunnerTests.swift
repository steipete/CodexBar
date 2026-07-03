import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
struct ClaudeLoginRunnerTests {
    @Test
    func `dedicated auth command opens browser prompt and completes successfully`() async throws {
        let fixture = try self.makeFixture(script: """
        #!/bin/sh
        printf 'args:%s\\n' "$*"
        printf 'Authenticate your account at (press ENTER to open in browser): '
        IFS= read -r _
        printf 'https://claude.ai/oauth/authorize?test=1\\n'
        printf 'Successfully logged in\\n'
        """)
        defer { fixture.remove() }

        let result = await ClaudeLoginRunner.run(
            timeout: 2,
            binary: fixture.executable.path,
            environment: fixture.environment,
            onPhaseChange: { _ in })

        guard case .success = result.outcome else {
            Issue.record("Expected success, got \(String(describing: result.outcome))")
            return
        }
        #expect(result.output.contains("args:auth login --claudeai"))
        #expect(result.authLink == "https://claude.ai/oauth/authorize?test=1")
    }

    @Test
    func `authorization URL alone is not treated as success`() async throws {
        let fixture = try self.makeFixture(script: """
        #!/bin/sh
        printf 'https://claude.ai/oauth/authorize?test=1\\n'
        /bin/sleep 5
        """)
        defer { fixture.remove() }

        let result = await ClaudeLoginRunner.run(
            timeout: 1,
            binary: fixture.executable.path,
            environment: fixture.environment,
            onPhaseChange: { _ in })

        guard case .timedOut = result.outcome else {
            Issue.record("Expected timeout, got \(String(describing: result.outcome))")
            return
        }
        #expect(result.authLink == "https://claude.ai/oauth/authorize?test=1")
    }

    @Test
    func `dedicated auth command preserves failure status`() async throws {
        let fixture = try self.makeFixture(script: """
        #!/bin/sh
        printf 'login failed\\n'
        exit 7
        """)
        defer { fixture.remove() }

        let result = await ClaudeLoginRunner.run(
            timeout: 2,
            binary: fixture.executable.path,
            environment: fixture.environment,
            onPhaseChange: { _ in })

        guard case .failed(status: 7) = result.outcome else {
            Issue.record("Expected status 7, got \(String(describing: result.outcome))")
            return
        }
        #expect(result.output.contains("login failed"))
    }

    private func makeFixture(script: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-claude-login-\(UUID().uuidString)", isDirectory: true)
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)

        let executable = binDirectory.appendingPathComponent("claude")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        return Fixture(
            root: root,
            executable: executable,
            environment: [
                "HOME": homeDirectory.path,
                "PATH": binDirectory.path,
            ])
    }

    private struct Fixture {
        let root: URL
        let executable: URL
        let environment: [String: String]

        func remove() {
            try? FileManager.default.removeItem(at: self.root)
        }
    }
}
