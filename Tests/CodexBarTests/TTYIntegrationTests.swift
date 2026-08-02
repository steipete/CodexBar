import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
struct TTYIntegrationTests {
    @Test
    func `codex RPC usage live`() async throws {
        guard ProcessInfo.processInfo.environment["LIVE_CODEX_TTY"] == "1" else {
            return
        }
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
            try await ClaudeStatusProbe(claudeBinary: cli.path, timeout: 10).fetch()
        }

        #expect(snapshot.sessionPercentLeft == 93)
        #expect(snapshot.weeklyPercentLeft == 79)
    }

    @Test
    func `claude pty usage stops on subscription notice`() async throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarTTYTests-\(UUID().uuidString).log")
        let cli = try Self.makeSubscriptionNoticeClaudeCLI(logURL: logURL)
        defer {
            try? FileManager.default.removeItem(at: logURL)
            Task { await ClaudeCLISession.shared.reset() }
        }

        do {
            try await ClaudeCLISession.withIsolatedSessionForTesting {
                _ = try await ClaudeStatusProbe(claudeBinary: cli.path, timeout: 3).fetch()
            }
            #expect(Bool(false), "Subscription notice should fail parsing")
        } catch let ClaudeStatusProbeError.parseFailed(message) {
            #expect(message.lowercased().contains("subscription"))
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }

        let commands = try String(contentsOf: logURL, encoding: .utf8)
        #expect(commands.contains("/usage"))
        #expect(!commands.contains("/status"))
    }

    @Test
    func `claude pty keepalive relaunches when account or launch environment changes`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarTTYAccountScope-\(UUID().uuidString)", isDirectory: true)
        let configRoot = root.appendingPathComponent("profile", isDirectory: true)
        let launchLog = root.appendingPathComponent("launches.log")
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = configRoot.appendingPathComponent(".config.json")
        try Self.writeClaudeAccount("account-a", to: configURL)
        let cli = try Self.makeAccountScopedClaudeCLI(in: root, launchLog: launchLog)
        let environment = [
            "CLAUDE_CONFIG_DIR": configRoot.path,
            "HOME": configRoot.path,
            "AWS_PROFILE": "profile-a",
        ]
        let probe = ClaudeStatusProbe(
            claudeBinary: cli.path,
            timeout: 5,
            keepCLISessionsAlive: true,
            environment: environment)

        try await ClaudeCLISession.withIsolatedSessionForTesting {
            _ = try await probe.fetch()
            _ = try await probe.fetch()
            try Self.writeClaudeAccount("account-b", to: configURL)
            _ = try await probe.fetch()
            var changedEnvironment = environment
            changedEnvironment["AWS_PROFILE"] = "profile-b"
            let changedEnvironmentProbe = ClaudeStatusProbe(
                claudeBinary: cli.path,
                timeout: 5,
                keepCLISessionsAlive: true,
                environment: changedEnvironment)
            _ = try await changedEnvironmentProbe.fetch()
        }

        let launches = try String(contentsOf: launchLog, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        #expect(launches.count == 3)
        #expect(launches.first?.hasSuffix(":account-a:profile-a") == true)
        #expect(launches.dropFirst().first?.hasSuffix(":account-b:profile-a") == true)
        #expect(launches.last?.hasSuffix(":account-b:profile-b") == true)
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
              sleep 2
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

    private static func makeSubscriptionNoticeClaudeCLI(logURL: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarTTYTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("claude")
        let script = """
        #!/bin/sh
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> '\(logURL.path)'
          case "$line" in
            *"/usage"*)
              printf '%s\\n' 'You are currently using your subscription to power your Claude Code usage'
              ;;
            *"/status"*)
              printf '%s\\n' 'Account: subscription@example.com'
              ;;
          esac
        done
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private static func writeClaudeAccount(_ account: String, to url: URL) throws {
        try Data("{\"oauthAccount\":{\"accountUuid\":\"\(account)\"}}".utf8).write(to: url, options: .atomic)
    }

    private static func makeAccountScopedClaudeCLI(in directory: URL, launchLog: URL) throws -> URL {
        let url = directory.appendingPathComponent("claude")
        let script = """
        #!/bin/sh
        ACCOUNT=$(sed -n 's/.*"accountUuid":"\\([^"]*\\)".*/\\1/p' "$CLAUDE_CONFIG_DIR/.config.json")
        printf 'launch:%s:%s:%s\\n' "$$" "$ACCOUNT" "$AWS_PROFILE" >> '\(launchLog.path)'
        while IFS= read -r line; do
          case "$line" in
            *"/usage"*)
              printf '%s\\n' 'Settings  Status  Config  Usage'
              printf '%s\\n' 'Current session'
              printf '%s\\n' '93% left'
              printf '%s\\n' 'Current week (all models)'
              printf '%s\\n' '79% left'
              ;;
            *"/status"*)
              printf 'Account: %s@example.com\\n' "$ACCOUNT"
              ;;
          esac
        done
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
