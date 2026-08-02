import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeCLIAuthStatusProbeTests {
    @Test
    func `parses logged in status`() {
        #expect(ClaudeCLIAuthStatusProbe.parseLoggedIn(#"{"loggedIn":true,"authMethod":"claude.ai"}"#))
    }

    @Test
    func `rejects logged out and malformed status`() {
        #expect(!ClaudeCLIAuthStatusProbe.parseLoggedIn(#"{"loggedIn":false,"authMethod":"none"}"#))
        #expect(!ClaudeCLIAuthStatusProbe.parseLoggedIn("not-json"))
        #expect(!ClaudeCLIAuthStatusProbe.parseLoggedIn(#"{"authMethod":"none"}"#))
    }

    @Test
    func `auth status uses the Claude owner working directory for relative profiles`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCLIAuthStatusProbe-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("probe", isDirectory: true)
        let profile = workingDirectory.appendingPathComponent("relative-profile", isDirectory: true)
        let invocationLog = root.appendingPathComponent("invocation.log")
        let binary = root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: profile.appendingPathComponent(".config.json"))
        defer { try? FileManager.default.removeItem(at: root) }

        let script = """
        #!/bin/sh
        if [ -f "$CLAUDE_CONFIG_DIR/.config.json" ]; then
          FOUND=yes
        else
          FOUND=no
        fi
        printf '%s|%s\n' "$PWD" "$FOUND" > '\(invocationLog.path)'
        printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai"}'
        """
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let loggedIn = await ClaudeCLIAuthStatusProbe.isLoggedIn(
            binary: binary.path,
            environment: [ClaudeConfigPaths.configDirectoryEnvironmentKey: "relative-profile"],
            workingDirectory: workingDirectory)

        #expect(loggedIn)
        #expect(try String(contentsOf: invocationLog, encoding: .utf8) == "\(workingDirectory.path)|yes\n")
    }
}
