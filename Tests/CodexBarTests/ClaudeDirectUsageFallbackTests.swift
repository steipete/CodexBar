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
    }

    @Test
    func `cli source falls back to direct usage when pty usage fails to load`() async throws {
        let cliLogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-direct-fallback-log-\(UUID().uuidString).txt")
        let log = InvocationLog(url: cliLogURL)
        let fakeCLI = try Self.makeDirectFallbackClaudeCLI(logURL: cliLogURL)
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: [
                "CLAUDE_CLI_PATH": fakeCLI.path,
                ClaudeOAuthCredentialsStore.environmentTokenKey: "oauth-token",
                ClaudeOAuthCredentialsStore.environmentScopesKey: "user:profile",
                "ANTHROPIC_ADMIN_KEY": "admin-token",
            ],
            dataSource: .cli)

        try await ClaudeCLISession.withIsolatedSessionForTesting {
            try await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting(fakeCLI.path) {
                do {
                    _ = try await fetcher.loadLatestUsage(model: "sonnet")
                    #expect(Bool(false), "Subscription-only usage should fail parsing")
                } catch let ClaudeUsageError.parseFailed(message) {
                    #expect(message.lowercased().contains("subscription"))
                } catch let ClaudeStatusProbeError.parseFailed(message) {
                    #expect(message.lowercased().contains("subscription"))
                }
            }
        }

        let invocations = log.contents()
        #expect(invocations.contains("pty-usage"))
        #expect(invocations.contains("direct-usage"))
        #expect(!invocations.contains("pty-secret-env"))
        #expect(!invocations.contains("direct-secret-env"))
    }

    @Test
    func `direct usage timeout keeps original pty failure`() async throws {
        let cliLogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-direct-timeout-log-\(UUID().uuidString).txt")
        let log = InvocationLog(url: cliLogURL)
        let fakeCLI = try Self.makeDirectTimeoutClaudeCLI(logURL: cliLogURL)
        let fetcher = ClaudeUsageFetcher(
            browserDetection: BrowserDetection(cacheTTL: 0),
            environment: ["CLAUDE_CLI_PATH": fakeCLI.path],
            dataSource: .cli)

        await ClaudeCLISession.withIsolatedSessionForTesting {
            await ClaudeCLIResolver.withResolvedBinaryPathOverrideForTesting(fakeCLI.path) {
                do {
                    _ = try await fetcher.loadLatestUsage(model: "sonnet")
                    #expect(Bool(false), "PTY failure should still surface")
                } catch let ClaudeStatusProbeError.parseFailed(message) {
                    #expect(message.lowercased().contains("could not load usage data"))
                } catch {
                    #expect(Bool(false), "Unexpected error: \(error)")
                }
            }
        }

        let invocations = log.contents()
        #expect(invocations.contains("pty-usage"))
        #expect(invocations.contains("direct-usage"))
    }

    private static func makeDirectFallbackClaudeCLI(logURL: URL) throws -> URL {
        try self.makeClaudeCLI(name: "claude-direct-fallback", logURL: logURL, scriptBody: """
        if [ "$1" = "/usage" ]; then
          printf 'direct-usage\\n' >> "$LOG_FILE"
          if [ -n "$CODEXBAR_CLAUDE_OAUTH_TOKEN" ] ||
             [ -n "$CODEXBAR_CLAUDE_OAUTH_SCOPES" ] ||
             [ -n "$ANTHROPIC_ADMIN_KEY" ]; then
            printf 'direct-secret-env\\n' >> "$LOG_FILE"
          fi
          printf '%s\\n' 'You are currently using your subscription to power your Claude Code usage'
          exit 0
        fi
        while IFS= read -r line; do
          case "$line" in
            *"/usage"*)
              printf 'pty-usage\\n' >> "$LOG_FILE"
              if [ -n "$CODEXBAR_CLAUDE_OAUTH_TOKEN" ] ||
                 [ -n "$CODEXBAR_CLAUDE_OAUTH_SCOPES" ] ||
                 [ -n "$ANTHROPIC_ADMIN_KEY" ]; then
                printf 'pty-secret-env\\n' >> "$LOG_FILE"
              fi
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

    private static func makeDirectTimeoutClaudeCLI(logURL: URL) throws -> URL {
        try self.makeClaudeCLI(name: "claude-direct-timeout", logURL: logURL, scriptBody: """
        if [ "$1" = "/usage" ]; then
          printf 'direct-usage\\n' >> "$LOG_FILE"
          sleep 30
          exit 0
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

    private static func makeClaudeCLI(name: String, logURL: URL, scriptBody: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent("claude")
        let script = """
        #!/bin/sh
        LOG_FILE='\(logURL.path)'
        \(scriptBody)
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: scriptURL.path)
        return scriptURL
    }
}
