import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CodexUsageFetcherFallbackTests {
    @Test
    func `recovers Codex CLI usage from rate limits decode error body`() async throws {
        let stubCLIPath = try self.makeDecodeErrorCodexCLI()
        let fetcher = UsageFetcher(environment: ["CODEX_CLI_PATH": stubCLIPath])

        let usage = try await fetcher.loadLatestUsage()

        #expect(usage.primary?.usedPercent == 40)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.secondary?.usedPercent == 13)
        #expect(usage.secondary?.windowMinutes == 10080)
    }

    @Test
    func `recovers Codex CLI credits from rate limits decode error body`() async throws {
        let stubCLIPath = try self.makeDecodeErrorCodexCLI()
        let fetcher = UsageFetcher(environment: ["CODEX_CLI_PATH": stubCLIPath])

        let credits = try await fetcher.loadLatestCredits()

        #expect(credits.remaining == 19.5)
    }

    private func makeDecodeErrorCodexCLI() throws -> String {
        let usageJSON = """
        {
          "user_id": "user-123",
          "account_id": "account-123",
          "email": "prolite@example.com",
          "plan_type": "prolite",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 40,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 6263,
              "reset_at": 1776214836
            },
            "secondary_window": {
              "used_percent": 13,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 575064,
              "reset_at": 1776783636
            }
          },
          "code_review_rate_limit": null,
          "additional_rate_limits": {},
          "credits": {
            "has_credits": true,
            "unlimited": false,
            "balance": "19.5"
          }
        }
        """

        let script = """
        #!/usr/bin/python3
        import json
        import sys

        USAGE_JSON = \(String(reflecting: usageJSON))
        ERROR_MESSAGE = (
            "failed to fetch codex rate limits: "
            "Decode error for https://chatgpt.com/backend-api/wham/usage/ "
            "decoded body contained unknown variant 'prolite'; "
            "content-type=application/json; body=" + USAGE_JSON
        )

        if "app-server" not in sys.argv:
            sys.exit(1)

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
                        "message": ERROR_MESSAGE
                    }
                }
            elif method == "account/read":
                payload = {
                    "id": identifier,
                    "result": {
                        "account": {
                            "type": "chatgpt",
                            "email": "prolite@example.com",
                            "planType": "prolite"
                        },
                        "requiresOpenaiAuth": False
                    }
                }
            else:
                payload = {"id": identifier, "result": {}}

            print(json.dumps(payload), flush=True)
        """

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-decode-error-\(UUID().uuidString)", isDirectory: false)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
}
