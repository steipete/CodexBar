import AppKit
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
struct CodexUsageFetcherFallbackTests {
    @Test
    func `CLI usage recovers from RPC decode mismatch body payload`() {
        let snapshot = UsageFetcher._recoverCodexRPCUsageFromErrorForTesting(
            Self.decodeMismatchBodyMessage)

        #expect(snapshot?.primary?.usedPercent == 4)
        #expect(snapshot?.primary?.windowMinutes == 300)
        #expect(snapshot?.secondary?.usedPercent == 19)
        #expect(snapshot?.secondary?.windowMinutes == 10080)
        #expect(snapshot?.accountEmail(for: UsageProvider.codex) == "prolite-test@example.com")
        #expect(snapshot?.loginMethod(for: UsageProvider.codex) == "prolite")
    }

    @Test
    func `CLI credits recover from RPC decode mismatch body payload`() {
        let credits = UsageFetcher._recoverCodexRPCCreditsFromErrorForTesting(Self.decodeMismatchBodyMessage)

        #expect(credits?.remaining == 0)
    }

    @Test
    func `CLI usage does not partially recover malformed RPC body without session lane`() {
        let snapshot = UsageFetcher._recoverCodexRPCUsageFromErrorForTesting(
            Self.partialDecodeBodyMessage)

        #expect(snapshot == nil)
    }

    @Test
    func `CLI usage falls back from RPC decode mismatch to TTY status`() async throws {
        let stubCLIPath = try self.makeDecodeMismatchStubCodexCLI(message: Self.decodeMismatchMessage)
        defer { try? FileManager.default.removeItem(atPath: stubCLIPath) }

        let fetcher = UsageFetcher(
            environment: ["CODEX_CLI_PATH": stubCLIPath],
            codexStatusFetcher: Self.stubTTYStatus)
        let snapshot = try await fetcher.loadLatestUsage()

        #expect(snapshot.primary?.usedPercent == 12)
        #expect(snapshot.primary?.windowMinutes == 300)
        #expect(snapshot.secondary?.usedPercent == 25)
        #expect(snapshot.secondary?.windowMinutes == 10080)
    }

    @Test
    func `CLI credits fall back from RPC decode mismatch to TTY status`() async throws {
        let stubCLIPath = try self.makeDecodeMismatchStubCodexCLI(message: Self.decodeMismatchMessage)
        defer { try? FileManager.default.removeItem(atPath: stubCLIPath) }

        let fetcher = UsageFetcher(
            environment: ["CODEX_CLI_PATH": stubCLIPath],
            codexStatusFetcher: Self.stubTTYStatus)
        let credits = try await fetcher.loadLatestCredits()

        #expect(credits.remaining == 42)
    }

    @Test
    func `CLI usage falls back to TTY when RPC body recovery misses session lane`() async throws {
        let stubCLIPath = try self.makeDecodeMismatchStubCodexCLI(message: Self.partialDecodeBodyMessage)
        defer { try? FileManager.default.removeItem(atPath: stubCLIPath) }

        let fetcher = UsageFetcher(
            environment: ["CODEX_CLI_PATH": stubCLIPath],
            codexStatusFetcher: Self.stubTTYStatus)
        let snapshot = try await fetcher.loadLatestUsage()

        #expect(snapshot.primary?.usedPercent == 12)
        #expect(snapshot.primary?.windowMinutes == 300)
        #expect(snapshot.secondary?.usedPercent == 25)
        #expect(snapshot.secondary?.windowMinutes == 10080)
    }

    // MARK: - Battery drain regression coverage (#842)

    /// Test A: When `account/rateLimits/read` never receives a reply, the RPC path
    /// must time out fast enough that the TTY fallback completes the call within
    /// a couple of seconds — not "never" as observed in production.
    @Test
    func `Hung rate-limits read times out and falls back to TTY within budget`() async throws {
        let stubCLIPath = try self.makeHungRateLimitsStubCodexCLI()
        defer { try? FileManager.default.removeItem(atPath: stubCLIPath) }

        let fetcher = UsageFetcher(
            environment: ["CODEX_CLI_PATH": stubCLIPath],
            codexStatusFetcher: Self.stubTTYStatus,
            initializeTimeoutSeconds: 0.5,
            requestTimeoutSeconds: 0.2)

        let started = Date()
        let snapshot = try await fetcher.loadLatestUsage()
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < 2.0, "Expected TTY fallback to complete in <2s, took \(elapsed)s")
        #expect(snapshot.primary?.usedPercent == 12)
        #expect(snapshot.secondary?.usedPercent == 25)
    }

    /// Test C: After Test A's hang, the fetcher must not have leaked a wedged
    /// process / pipe — a follow-up call must also complete in budget.
    @Test
    func `Repeated hung RPC requests stay bounded across calls`() async throws {
        let stubCLIPath = try self.makeHungRateLimitsStubCodexCLI()
        defer { try? FileManager.default.removeItem(atPath: stubCLIPath) }

        let fetcher = UsageFetcher(
            environment: ["CODEX_CLI_PATH": stubCLIPath],
            codexStatusFetcher: Self.stubTTYStatus,
            initializeTimeoutSeconds: 0.5,
            requestTimeoutSeconds: 0.2)

        _ = try await fetcher.loadLatestUsage()
        let started = Date()
        let snapshot = try await fetcher.loadLatestUsage()
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < 2.0, "Second call should also complete in <2s, took \(elapsed)s")
        #expect(snapshot.primary?.usedPercent == 12)
    }

    /// Test D: The TTY fallback also has a bounded execution. If the TTY path
    /// itself hangs, the fetcher must throw within `ttyTimeoutSeconds`.
    @Test
    func `Hanging TTY fallback also times out within budget`() async throws {
        let stubCLIPath = try self.makeHungRateLimitsStubCodexCLI()
        defer { try? FileManager.default.removeItem(atPath: stubCLIPath) }

        let hangingTTY: @Sendable ([String: String], Bool) async throws -> CodexStatusSnapshot = { _, _ in
            try await Task.sleep(for: .seconds(30))
            return CodexStatusSnapshot(
                credits: nil,
                fiveHourPercentLeft: nil,
                weeklyPercentLeft: nil,
                fiveHourResetDescription: nil,
                weeklyResetDescription: nil,
                fiveHourResetsAt: nil,
                weeklyResetsAt: nil,
                rawText: "")
        }

        let fetcher = UsageFetcher(
            environment: ["CODEX_CLI_PATH": stubCLIPath],
            codexStatusFetcher: hangingTTY,
            initializeTimeoutSeconds: 0.5,
            requestTimeoutSeconds: 0.2,
            ttyTimeoutSeconds: 0.5)

        let started = Date()
        do {
            _ = try await fetcher.loadLatestUsage()
            Issue.record("Expected fetcher to throw when both RPC and TTY hang")
        } catch {
            // Either path's timeout is acceptable; what matters is bounded duration.
        }
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 2.0, "Both-hang case must terminate fast, took \(elapsed)s")
    }

    /// Test B: When an error is recorded for a provider, `isStale` returns true
    /// and the menu-bar animation must NOT start. (Production bug: hung RPC
    /// recorded no error so `isStale = false` and the 60 FPS DisplayLink ran
    /// indefinitely.)
    @Test
    @MainActor
    func `Recorded error marks provider stale and stops menu-bar animation`() {
        _ = NSApplication.shared

        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "BatteryDrain-StaleErrorStops"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let registry = ProviderRegistry.shared
        if let meta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: meta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        // No snapshot, but an error is recorded — exactly the post-fix shape we
        // get when the RPC times out and the fallback also fails.
        store._setErrorForTesting("simulated codex RPC timeout", provider: .codex)

        #expect(store.isStale(provider: .codex) == true)

        let env = ProcessInfo.processInfo.environment
        let statusBar: NSStatusBar = (env["GITHUB_ACTIONS"] == "true" || env["CI"] == "true")
            ? .system
            : NSStatusBar()

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: statusBar)

        #expect(
            controller.needsMenuBarIconAnimation() == false,
            "Animation must not run when provider is stale (errors[provider] != nil)")
        #expect(controller.animationDriver == nil)
    }

    private static let decodeMismatchBodyMessage = """
    failed to fetch codex rate limits: Decode error for https://chatgpt.com/backend-api/wham/usage:
    unknown variant `prolite`, expected one of `guest`, `free`, `go`, `plus`, `pro`;
    content-type=application/json; body={
      "user_id": "user-TEST",
      "account_id": "account-TEST",
      "email": "prolite-test@example.com",
      "plan_type": "prolite",
      "rate_limit": {
        "allowed": true,
        "limit_reached": false,
        "primary_window": {
          "used_percent": 4,
          "limit_window_seconds": 18000,
          "reset_after_seconds": 8657,
          "reset_at": 1776216359
        },
        "secondary_window": {
          "used_percent": 19,
          "limit_window_seconds": 604800,
          "reset_after_seconds": 187681,
          "reset_at": 1776395384
        }
      },
      "credits": {
        "has_credits": false,
        "unlimited": false,
        "overage_limit_reached": false,
        "balance": "0E-10"
      }
    }
    """

    private static let decodeMismatchMessage = """
    failed to fetch codex rate limits: Decode error for https://chatgpt.com/backend-api/wham/usage:
    unknown variant `prolite`, expected one of `guest`, `free`, `go`, `plus`, `pro`
    """

    private static let partialDecodeBodyMessage = """
    failed to fetch codex rate limits: Decode error for https://chatgpt.com/backend-api/wham/usage:
    unknown variant `prolite`, expected one of `guest`, `free`, `go`, `plus`, `pro`;
    content-type=application/json; body={
      "email": "prolite-test@example.com",
      "plan_type": "prolite",
      "rate_limit": {
        "allowed": true,
        "limit_reached": false,
        "primary_window": {
          "used_percent": "oops",
          "limit_window_seconds": 18000,
          "reset_at": 1776216359
        },
        "secondary_window": {
          "used_percent": 19,
          "limit_window_seconds": 604800,
          "reset_after_seconds": 187681,
          "reset_at": 1776395384
        }
      }
    }
    """

    private static func stubTTYStatus(
        environment _: [String: String],
        keepCLISessionsAlive _: Bool) async throws -> CodexStatusSnapshot
    {
        CodexStatusSnapshot(
            credits: 42,
            fiveHourPercentLeft: 88,
            weeklyPercentLeft: 75,
            fiveHourResetDescription: nil,
            weeklyResetDescription: nil,
            fiveHourResetsAt: nil,
            weeklyResetsAt: nil,
            rawText: "Credits: 42 credits\n5h limit: [#####] 88% left\nWeekly limit: [##] 75% left\n")
    }

    /// Stub `codex` CLI that accepts `initialize`, hangs forever on
    /// `account/rateLimits/read`, but answers `account/read` and TTY (`/status`)
    /// invocations normally. Models the exact production failure that caused
    /// #842 — the RPC stream never returns, no error is recorded, and the
    /// menu-bar animation pins at full FPS until the user quits.
    private func makeHungRateLimitsStubCodexCLI() throws -> String {
        let script = """
        #!/usr/bin/python3
        import json
        import sys
        import time

        args = sys.argv[1:]
        if "app-server" in args:
            for line in sys.stdin:
                if not line.strip():
                    continue
                message = json.loads(line)
                method = message.get("method")
                if method == "initialized":
                    continue

                identifier = message.get("id")
                if method == "initialize":
                    payload = {"id": identifier, "result": {}}
                    print(json.dumps(payload), flush=True)
                elif method == "account/rateLimits/read":
                    # Never reply — this is the production failure mode.
                    time.sleep(30)
                elif method == "account/read":
                    payload = {
                        "id": identifier,
                        "result": {
                            "account": {
                                "type": "chatgpt",
                                "email": "stub@example.com",
                                "planType": "plus"
                            },
                            "requiresOpenaiAuth": False
                        }
                    }
                    print(json.dumps(payload), flush=True)
                else:
                    payload = {"id": identifier, "result": {}}
                    print(json.dumps(payload), flush=True)
        else:
            sys.stdout.write("Credits: 42 credits\\n5h limit: [#####] 88% left\\nWeekly limit: [##] 75% left\\n")
            sys.stdout.flush()
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-hung-stub-\(UUID().uuidString)", isDirectory: false)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func makeDecodeMismatchStubCodexCLI(
        message: String = Self.decodeMismatchBodyMessage)
        throws -> String
    {
        let script = """
        #!/usr/bin/python3
        import json
        import sys

        args = sys.argv[1:]
        if "app-server" in args:
            for line in sys.stdin:
                if not line.strip():
                    continue
                message = json.loads(line)
                method = message.get("method")
                if method == "initialized":
                    continue

                identifier = message.get("id")
                if method == "initialize":
                    payload = {"id": identifier, "result": {}}
                elif method == "account/rateLimits/read":
                    payload = {
                        "id": identifier,
                        "error": {
                            "message": '''\(message)'''
                        }
                    }
                elif method == "account/read":
                    payload = {
                        "id": identifier,
                        "result": {
                            "account": {
                                "type": "chatgpt",
                                "email": "stub@example.com",
                                "planType": "prolite"
                            },
                            "requiresOpenaiAuth": False
                        }
                    }
                else:
                    payload = {"id": identifier, "result": {}}

                print(json.dumps(payload), flush=True)
        else:
            sys.stdout.write("Credits: 42 credits\\n5h limit: [#####] 88% left\\nWeekly limit: [##] 75% left\\n")
            sys.stdout.flush()
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-fallback-stub-\(UUID().uuidString)", isDirectory: false)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
}
