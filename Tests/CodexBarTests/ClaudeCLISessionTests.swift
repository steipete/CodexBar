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
        let firstConfig = directory.appendingPathComponent("profile-a", isDirectory: true)
        let firstSecureStorage = directory.appendingPathComponent("secure-a", isDirectory: true)
        let firstHome = directory.appendingPathComponent("home-a", isDirectory: true)
        let secondConfig = directory.appendingPathComponent("profile-b", isDirectory: true)
        let secondSecureStorage = directory.appendingPathComponent("secure-b", isDirectory: true)
        let secondHome = directory.appendingPathComponent("home-b", isDirectory: true)
        let firstStaleTranscript = try Self.makeStaleProbeTranscript(in: firstConfig)
        let secondStaleTranscript = try Self.makeStaleProbeTranscript(in: secondConfig)

        var firstEnvironment = ProcessInfo.processInfo.environment
        firstEnvironment["CODEXBAR_DISABLE_CLAUDE_WATCHDOG"] = "1"
        firstEnvironment["CLAUDE_CONFIG_DIR"] = firstConfig.path
        firstEnvironment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = firstSecureStorage.path
        firstEnvironment["HOME"] = firstHome.path

        var secondEnvironment = firstEnvironment
        secondEnvironment["CLAUDE_CONFIG_DIR"] = secondConfig.path
        secondEnvironment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = secondSecureStorage.path
        secondEnvironment["HOME"] = secondHome.path

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

            #expect(first.contains("Account: \(firstConfig.path)"))
            #expect(second.contains("Account: \(secondConfig.path)"))
            #expect(reused.contains("Account: \(secondConfig.path)"))
        } catch {
            await session.reset()
            throw error
        }

        let launches = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(launches == [
            "start:\(firstConfig.path):\(firstSecureStorage.path):\(firstHome.path)",
            "start:\(secondConfig.path):\(secondSecureStorage.path):\(secondHome.path)",
        ])
        #expect(!FileManager.default.fileExists(atPath: firstStaleTranscript.path))
        #expect(!FileManager.default.fileExists(atPath: secondStaleTranscript.path))
    }

    @Test
    func `overlapping profile captures serialize PTY ownership`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-claude-overlap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let logURL = directory.appendingPathComponent("launches.log")
        let cliURL = try Self.makeEnvironmentEchoingClaudeCLI(in: directory, logURL: logURL)
        let session = ClaudeCLISession()
        let firstConfig = directory.appendingPathComponent("profile-a", isDirectory: true)
        let secondConfig = directory.appendingPathComponent("profile-b", isDirectory: true)

        var firstEnvironment = ProcessInfo.processInfo.environment
        firstEnvironment["CODEXBAR_DISABLE_CLAUDE_WATCHDOG"] = "1"
        firstEnvironment["CLAUDE_CONFIG_DIR"] = firstConfig.path
        var secondEnvironment = firstEnvironment
        secondEnvironment["CLAUDE_CONFIG_DIR"] = secondConfig.path

        let firstTask = Task {
            try await session.capture(
                subcommand: "/status",
                binary: cliURL.path,
                timeout: 5,
                environment: firstEnvironment,
                idleTimeout: 0.1,
                settleAfterStop: 0)
        }
        do {
            try await Self.waitForLaunchCount(1, at: logURL)
        } catch {
            firstTask.cancel()
            await session.reset()
            throw error
        }

        let secondTask = Task {
            try await session.capture(
                subcommand: "/status",
                binary: cliURL.path,
                timeout: 5,
                environment: secondEnvironment,
                idleTimeout: 0.1,
                settleAfterStop: 0)
        }

        do {
            let first = try await firstTask.value
            let second = try await secondTask.value
            await session.reset()

            #expect(first.contains("Account: \(firstConfig.path)"))
            #expect(!first.contains("Account: \(secondConfig.path)"))
            #expect(second.contains("Account: \(secondConfig.path)"))
        } catch {
            firstTask.cancel()
            secondTask.cancel()
            await session.reset()
            throw error
        }

        let launches = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(launches.map { $0.split(separator: ":")[1] } == [
            Substring(firstConfig.path),
            Substring(secondConfig.path),
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

    private static func makeStaleProbeTranscript(in configDirectory: URL) throws -> URL {
        let projectDirectory = configDirectory
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(
                ClaudeProbeSessionArtifactCleaner.claudeProjectDirectoryName(
                    for: ClaudeStatusProbe.probeWorkingDirectoryURL()),
                isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let transcript = projectDirectory.appendingPathComponent("stale.jsonl")
        try Data("{}\n".utf8).write(to: transcript)
        return transcript
    }

    private static func waitForLaunchCount(_ expectedCount: Int, at logURL: URL) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let count = (try? String(contentsOf: logURL, encoding: .utf8))?
                .split(separator: "\n")
                .count ?? 0
            if count >= expectedCount {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw ClaudeCLISession.SessionError.timedOut
    }
}
