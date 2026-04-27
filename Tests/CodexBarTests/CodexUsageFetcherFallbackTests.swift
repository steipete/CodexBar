import Foundation
import Testing
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
