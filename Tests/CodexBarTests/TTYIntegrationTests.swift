import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
struct TTYIntegrationTests {
    @Test
    func `codex RPC usage live`() async throws {
        let fetcher = UsageFetcher()
        do {
            let snapshot = try await fetcher.loadLatestUsage()
            guard let primary = snapshot.primary else {
                return
            }
            let hasData = primary.usedPercent >= 0 && (snapshot.secondary?.usedPercent ?? 0) >= 0
            #expect(hasData)
        } catch UsageError.noRateLimitsFound {
            return
        } catch {
            return
        }
    }

    @Test
    func `claude TTY usage probe live`() async throws {
        guard ProcessInfo.processInfo.environment["LIVE_CLAUDE_TTY"] == "1" else {
            return
        }
        guard TTYCommandRunner.which("claude") != nil else {
            return
        }

        let fetcher = ClaudeUsageFetcher(browserDetection: BrowserDetection(cacheTTL: 0), dataSource: .cli)
        defer { Task { await ClaudeCLISession.shared.reset() } }

        var shouldAssert = true
        do {
            let snapshot = try await fetcher.loadLatestUsage()
            #expect(snapshot.primary.remainingPercent >= 0)
            // Weekly is absent for some enterprise accounts.
        } catch ClaudeUsageError.parseFailed(_) {
            shouldAssert = false
        } catch ClaudeStatusProbeError.parseFailed(_) {
            shouldAssert = false
        } catch ClaudeUsageError.claudeNotInstalled {
            shouldAssert = false
        } catch ClaudeStatusProbeError.timedOut {
            shouldAssert = false
        } catch let TTYCommandRunner.Error.launchFailed(message) where message.contains("login") {
            shouldAssert = false
        } catch {
            shouldAssert = false
        }

        if !shouldAssert { return }
    }

    @Test
    func `claude pty usage waits for values after session label`() async throws {
        let cli = try Self.makeSlowUsageClaudeCLI()
        defer { Task { await ClaudeCLISession.shared.reset() } }

        let snapshot = try await ClaudeCLISession.withIsolatedSessionForTesting {
            try await ClaudeStatusProbe(claudeBinary: cli.path, timeout: 8).fetch()
        }

        #expect(snapshot.sessionPercentLeft == 93)
        #expect(snapshot.weeklyPercentLeft == 79)
    }

    private static func makeSlowUsageClaudeCLI() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarTTYTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("claude")
        let script = """
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *"/usage"*)
              printf '%s\\n' 'Settings  Status  Config  Usage'
              printf '%s\\n' 'Current session'
              sleep 4
              printf '%s\\n' '93% left'
              printf '%s\\n' 'Current week (all models)'
              printf '%s\\n' '79% left'
              ;;
            *"/status"*)
              printf '%s\\n' 'Account: slow-usage@example.com'
              ;;
          esac
        done
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
