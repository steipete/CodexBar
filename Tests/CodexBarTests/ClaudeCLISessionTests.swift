import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeCLISessionTests {
    @Test
    func `Claude session reuse requires explicit request and account scoped ownership`() {
        #expect(!ClaudeStatusProbe.shouldKeepCLISessionAlive(requested: false))
        #expect(ClaudeStatusProbe.shouldKeepCLISessionAlive(requested: true))
    }

    @Test
    func `Claude session scope changes with account and config root and fails closed without identity`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-claude-scope-\(UUID().uuidString)", isDirectory: true)
        let firstRoot = root.appendingPathComponent("first", isDirectory: true)
        let secondRoot = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstEnvironment = ["CLAUDE_CONFIG_DIR": firstRoot.path]
        let secondEnvironment = ["CLAUDE_CONFIG_DIR": secondRoot.path]
        let configURL = firstRoot.appendingPathComponent(".config.json")
        try Data(#"{"oauthAccount":{"accountUuid":"account-a"}}"#.utf8).write(to: configURL)
        let accountA = ClaudeAccountProfile.sessionScope(environment: firstEnvironment)
        let accountARepeat = ClaudeAccountProfile.sessionScope(environment: firstEnvironment)

        try Data(#"{"oauthAccount":{"accountUuid":"account-b"}}"#.utf8).write(to: configURL)
        let accountB = ClaudeAccountProfile.sessionScope(environment: firstEnvironment)
        try Data(#"{"oauthAccount":{"accountUuid":"account-b"}}"#.utf8)
            .write(to: secondRoot.appendingPathComponent(".config.json"))
        let accountBInSecondRoot = ClaudeAccountProfile.sessionScope(environment: secondEnvironment)
        let secureRoot = root.appendingPathComponent("secure", isDirectory: true)
        let accountBInDifferentSecureRoot = ClaudeAccountProfile.sessionScope(environment: [
            "CLAUDE_CONFIG_DIR": firstRoot.path,
            "CLAUDE_SECURESTORAGE_CONFIG_DIR": secureRoot.path,
        ])
        try FileManager.default.removeItem(at: configURL)
        let firstFallbackID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondFallbackID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let missingFirst = ClaudeAccountProfile.sessionScope(
            environment: firstEnvironment,
            fallbackID: firstFallbackID)
        let missingSecond = ClaudeAccountProfile.sessionScope(
            environment: firstEnvironment,
            fallbackID: secondFallbackID)

        #expect(accountA == accountARepeat)
        #expect(accountA != accountB)
        #expect(accountB != accountBInSecondRoot)
        #expect(accountB != accountBInDifferentSecureRoot)
        #expect(missingFirst != missingSecond)
    }

    @Test
    func `profile environment launches and identifies the reusable session`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-claude-environment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let logURL = directory.appendingPathComponent("launches.log")
        let cliURL = try Self.makeEnvironmentEchoingClaudeCLI(in: directory, logURL: logURL)
        let session = ClaudeCLISession()

        var firstEnvironment = ProcessInfo.processInfo.environment
        firstEnvironment["CODEXBAR_DISABLE_CLAUDE_WATCHDOG"] = "1"
        firstEnvironment["CLAUDE_CONFIG_DIR"] = "/tmp/codexbar-profile-a"
        firstEnvironment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = "/tmp/codexbar-secure-a"
        firstEnvironment["HOME"] = "/tmp/codexbar-home-a"

        var secondEnvironment = firstEnvironment
        secondEnvironment["CLAUDE_CONFIG_DIR"] = "/tmp/codexbar-profile-b"
        secondEnvironment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = "/tmp/codexbar-secure-b"
        secondEnvironment["HOME"] = "/tmp/codexbar-home-b"

        do {
            let first = try await session.capture(
                subcommand: "/status",
                binary: cliURL.path,
                timeout: 2,
                environment: firstEnvironment,
                idleTimeout: 0.1,
                settleAfterStop: 0)
            let second = try await session.capture(
                subcommand: "/status",
                binary: cliURL.path,
                timeout: 2,
                environment: secondEnvironment,
                idleTimeout: 0.1,
                settleAfterStop: 0)
            let reused = try await session.capture(
                subcommand: "/status",
                binary: cliURL.path,
                timeout: 2,
                environment: secondEnvironment,
                idleTimeout: 0.1,
                settleAfterStop: 0)
            await session.reset()

            #expect(first.contains("Account: /tmp/codexbar-profile-a"))
            #expect(second.contains("Account: /tmp/codexbar-profile-b"))
            #expect(reused.contains("Account: /tmp/codexbar-profile-b"))
        } catch {
            await session.reset()
            throw error
        }

        let launches = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(launches == [
            "start:/tmp/codexbar-profile-a:/tmp/codexbar-secure-a:/tmp/codexbar-home-a",
            "start:/tmp/codexbar-profile-b:/tmp/codexbar-secure-b:/tmp/codexbar-home-b",
        ])
    }

    @Test
    func `probe launch reuses one persisted session identifier`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-claude-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = ClaudeCLISession.loadOrCreateProbeSessionID(in: directory)
        let second = ClaudeCLISession.loadOrCreateProbeSessionID(in: directory)

        #expect(first == second)
        #expect(ClaudeCLISession.launchArguments(sessionID: first) == [
            "--allowed-tools",
            "",
            "--session-id",
            first.uuidString.lowercased(),
        ])

        let file = directory.appendingPathComponent(".codexbar-session-id")
        let persisted = try String(contentsOf: file, encoding: .utf8)
        #expect(persisted == first.uuidString.lowercased())
        #if os(macOS) || os(Linux)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue == 0o600)
        #endif
    }

    @Test
    func `invalid persisted probe session identifier is replaced`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-claude-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent(".codexbar-session-id")
        try "invalid".write(to: file, atomically: true, encoding: .utf8)

        let sessionID = ClaudeCLISession.loadOrCreateProbeSessionID(in: directory)
        let persisted = try String(contentsOf: file, encoding: .utf8)

        #expect(persisted == sessionID.uuidString.lowercased())
    }

    @Test
    func `unwritable probe directory keeps one process local fallback identifier`() {
        let directory = URL(fileURLWithPath: "/dev/null/CodexBar-ClaudeProbe", isDirectory: true)

        let first = ClaudeCLISession.loadOrCreateProbeSessionID(in: directory)
        let second = ClaudeCLISession.loadOrCreateProbeSessionID(in: directory)

        #expect(first == second)
    }

    private static func makeEnvironmentEchoingClaudeCLI(in directory: URL, logURL: URL) throws -> URL {
        let url = directory.appendingPathComponent("claude")
        let script = """
        #!/bin/sh
        printf 'start:%s:%s:%s\n' \
          "$CLAUDE_CONFIG_DIR" \
          "$CLAUDE_SECURESTORAGE_CONFIG_DIR" \
          "$HOME" >> '\(logURL.path)'
        while IFS= read -r line; do
          case "$line" in
            *"/status"*)
              printf 'Account: %s\n' "$CLAUDE_CONFIG_DIR"
              ;;
          esac
        done
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
