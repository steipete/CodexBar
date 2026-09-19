import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeDirectUsageFallbackTests {
    private final class InvocationLog: @unchecked Sendable {
        private let url: URL
        private let lock = NSLock()

        init(url: URL) {
            self.url = url
        }

        func contents() -> String {
            self.lock.withLock {
                (try? String(contentsOf: self.url, encoding: .utf8)) ?? ""
            }
        }

        func arguments(for mode: String) -> [String] {
            let prefix = "\(mode)-arg:"
            return self.contents().split(separator: "\n").compactMap { line in
                line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
            }
        }

        func waitForDirectUsage() async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: TestTimingBudget.scaled(.seconds(10)))
            while !self.contents().contains("direct-usage\n") {
                try #require(clock.now < deadline, "The direct fallback did not start")
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private struct Fixture: Sendable {
        let directory: URL
        let cliURL: URL
        let log: InvocationLog
        let environment: [String: String]
        let savedSettings: [URL: Data]

        func loadUsage() async throws -> ClaudeUsageSnapshot {
            let fetcher = ClaudeUsageFetcher(
                browserDetection: BrowserDetection(cacheTTL: 0),
                environment: self.environment,
                dataSource: .cli)
            return try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                try await ClaudeCLISession.withIsolatedSessionForTesting {
                    try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting(self.cliURL.path) {
                        try await fetcher.loadLatestUsage(model: "sonnet")
                    }
                }
            }
        }

        func expectProbeInvocations() throws {
            let invocations = self.log.contents()
            #expect(invocations.contains("pty-usage"))
            #expect(invocations.contains("direct-usage"))
            #expect(invocations.contains("pty-auto-updater-disabled"))
            #expect(invocations.contains("direct-auto-updater-disabled"))
            #expect(!invocations.contains("secret-env"))
            #expect(!invocations.contains("remote-registration-would-occur"))
            #expect(self.log.arguments(for: "direct") == [
                "--settings", #"{"remoteControlAtStartup":false}"#, "/usage",
            ])
            let ptyArguments = self.log.arguments(for: "pty")
            #expect(Array(ptyArguments.dropLast()) == [
                "--allowed-tools", "", "--strict-mcp-config",
                "--settings", #"{"remoteControlAtStartup":false}"#, "--session-id",
            ])
            let sessionID = try #require(ptyArguments.last)
            #expect(UUID(uuidString: sessionID) != nil)
            for (url, original) in self.savedSettings {
                #expect(try Data(contentsOf: url) == original)
            }
        }
    }

    @Test
    func `passive claude probes always disable the cli auto updater`() {
        let environment = ClaudeCLISession.launchEnvironment(baseEnv: [
            "DISABLE_AUTOUPDATER": "0",
            ClaudeOAuthCredentialsStore.environmentTokenKey: "oauth-token",
            "ANTHROPIC_API_KEY": "api-token",
        ])

        #expect(environment["DISABLE_AUTOUPDATER"] == "1")
        #expect(environment[ClaudeOAuthCredentialsStore.environmentTokenKey] == nil)
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
    }

    @Test
    func `cli source falls back to direct usage without remote control when pty usage fails`() async throws {
        let fixture = try Self.makeDirectFallbackClaudeCLI()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        do {
            _ = try await fixture.loadUsage()
            #expect(Bool(false), "Subscription-only usage should fail parsing")
        } catch let ClaudeUsageError.parseFailed(message) {
            #expect(message.lowercased().contains("subscription"))
        } catch let ClaudeStatusProbeError.parseFailed(message) {
            #expect(message.lowercased().contains("subscription"))
        }

        try fixture.expectProbeInvocations()
    }

    @Test
    func `direct usage timeout keeps original pty failure`() async throws {
        let fixture = try Self.makeDirectTimeoutClaudeCLI()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        do {
            _ = try await fixture.loadUsage()
            #expect(Bool(false), "PTY failure should still surface")
        } catch let ClaudeStatusProbeError.parseFailed(message) {
            #expect(message.lowercased().contains("could not load usage data"))
        }

        try fixture.expectProbeInvocations()
    }

    @Test
    func `cancelling direct usage preserves cancellation without retrying`() async throws {
        let fixture = try Self.makeDirectTimeoutClaudeCLI()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let task = Task {
            try await fixture.loadUsage()
        }
        do {
            try await fixture.log.waitForDirectUsage()
        } catch {
            task.cancel()
            _ = await task.result
            throw error
        }
        task.cancel()
        do {
            _ = try await task.value
            #expect(Bool(false), "The direct fallback should propagate cancellation")
        } catch is CancellationError {
            // Cancellation must replace the earlier PTY failure and stop retrying.
        }

        try fixture.expectProbeInvocations()
    }

    private static func makeDirectFallbackClaudeCLI() throws -> Fixture {
        try self.makeClaudeCLI(name: "claude-direct-fallback", scriptBody: """
        if [ "$MODE" = "direct" ]; then
          printf 'direct-usage\\n' >> "$LOG_FILE"
          printf '%s\\n' 'You are currently using your subscription to power your Claude Code usage'
          exit 0
        fi
        while IFS= read -r line; do
          case "$line" in
            *"/usage"*)
              printf 'pty-usage\\n' >> "$LOG_FILE"
              printf '%s\\n' 'Failed to load usage data'
              ;;
            *"/status"*)
              printf 'pty-status\\n' >> "$LOG_FILE"
              printf '%s\\n' 'Account: subscription@example.com'
              ;;
          esac
        done
        """)
    }

    private static func makeDirectTimeoutClaudeCLI() throws -> Fixture {
        try self.makeClaudeCLI(name: "claude-direct-timeout", scriptBody: """
        if [ "$MODE" = "direct" ]; then
          printf 'direct-usage\\n' >> "$LOG_FILE"
          exec /bin/sleep 30
        fi
        while IFS= read -r line; do
          case "$line" in
            *"/usage"*)
              printf 'pty-usage\\n' >> "$LOG_FILE"
              printf '%s\\n' 'Failed to load usage data'
              ;;
          esac
        done
        """)
    }

    private static func makeClaudeCLI(name: String, scriptBody: String) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let profile = directory.appendingPathComponent("profile", isDirectory: true)
        let secureStorage = directory.appendingPathComponent("secure", isDirectory: true)
        let settings = Data(#"{"remoteControlAtStartup":true,"env":{"SYNTHETIC_SENTINEL":"unchanged"}}"#.utf8)
        let settingsURLs = [
            home.appendingPathComponent(".claude/settings.json"),
            profile.appendingPathComponent("settings.json"),
        ]
        for url in settingsURLs {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try settings.write(to: url)
        }
        try FileManager.default.createDirectory(at: secureStorage, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent("claude")
        let logURL = directory.appendingPathComponent("invocations.log")
        let script = """
        #!/bin/sh
        LOG_FILE='\(logURL.path)'
        MODE=pty
        for argument in "$@"; do
          if [ "$argument" = "/usage" ]; then MODE=direct; fi
        done
        for argument in "$@"; do
          printf '%s-arg:%s\\n' "$MODE" "$argument" >> "$LOG_FILE"
        done
        REMOTE_CONTROL_DISABLED=0
        EXPECT_SETTINGS=0
        for argument in "$@"; do
          if [ "$EXPECT_SETTINGS" = "1" ] && [ "$argument" = '{"remoteControlAtStartup":false}' ]; then
            REMOTE_CONTROL_DISABLED=1
          fi
          EXPECT_SETTINGS=0
          if [ "$argument" = "--settings" ]; then EXPECT_SETTINGS=1; fi
        done
        if [ "$REMOTE_CONTROL_DISABLED" != "1" ]; then
          printf '%s-remote-registration-would-occur\\n' "$MODE" >> "$LOG_FILE"
        fi
        if [ "$DISABLE_AUTOUPDATER" = "1" ]; then
          printf '%s-auto-updater-disabled\\n' "$MODE" >> "$LOG_FILE"
        fi
        if [ -n "$CODEXBAR_CLAUDE_OAUTH_TOKEN" ] ||
           [ -n "$CODEXBAR_CLAUDE_OAUTH_SCOPES" ] ||
           [ -n "$ANTHROPIC_API_KEY" ] ||
           [ -n "$ANTHROPIC_ADMIN_KEY" ]; then
          printf '%s-secret-env\\n' "$MODE" >> "$LOG_FILE"
        fi
        \(scriptBody)
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: scriptURL.path)
        return Fixture(
            directory: directory,
            cliURL: scriptURL,
            log: InvocationLog(url: logURL),
            environment: [
                "CLAUDE_CLI_PATH": scriptURL.path,
                "CODEXBAR_DISABLE_CLAUDE_WATCHDOG": "1",
                "HOME": home.path,
                "CLAUDE_CONFIG_DIR": profile.path,
                "CLAUDE_SECURESTORAGE_CONFIG_DIR": secureStorage.path,
                "DISABLE_AUTOUPDATER": "0",
                ClaudeOAuthCredentialsStore.environmentTokenKey: "oauth-token",
                ClaudeOAuthCredentialsStore.environmentScopesKey: "user:profile",
                "ANTHROPIC_API_KEY": "api-token",
                "ANTHROPIC_ADMIN_KEY": "admin-token",
            ],
            savedSettings: Dictionary(uniqueKeysWithValues: settingsURLs.map { ($0, settings) }))
    }
}
