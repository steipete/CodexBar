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
    func `CLI credits recover from RPC error body when usage windows are unusable`() async throws {
        let stubCLIPath = try self.makeDecodeMismatchStubCodexCLI(message: Self.creditsOnlyDecodeMismatchBodyMessage)
        defer { try? FileManager.default.removeItem(atPath: stubCLIPath) }

        let fetcher = UsageFetcher(environment: ["CODEX_CLI_PATH": stubCLIPath])
        let credits = try await fetcher.loadLatestCredits()

        #expect(credits.remaining == 14.5)
        await #expect(throws: UsageError.noRateLimitsFound) {
            _ = try await fetcher.loadLatestUsage()
        }
    }

    @Test
    func `CLI usage does not partially recover malformed RPC body without session lane`() {
        let snapshot = UsageFetcher._recoverCodexRPCUsageFromErrorForTesting(
            Self.partialDecodeBodyMessage)

        #expect(snapshot == nil)
    }

    @Test
    func `CLI usage recovers from RPC body without TTY fallback`() async throws {
        let stubCLIPath = try self.makeDecodeMismatchStubCodexCLI(message: Self.decodeMismatchBodyMessage)
        defer { try? FileManager.default.removeItem(atPath: stubCLIPath) }

        let fetcher = UsageFetcher(environment: ["CODEX_CLI_PATH": stubCLIPath])
        let snapshot = try await fetcher.loadLatestUsage()

        #expect(snapshot.primary?.usedPercent == 4)
        #expect(snapshot.primary?.windowMinutes == 300)
        #expect(snapshot.secondary?.usedPercent == 19)
        #expect(snapshot.secondary?.windowMinutes == 10080)
    }

    @Test
    func `CLI credits recover from RPC body without TTY fallback`() async throws {
        let stubCLIPath = try self.makeDecodeMismatchStubCodexCLI(message: Self.decodeMismatchBodyMessage)
        defer { try? FileManager.default.removeItem(atPath: stubCLIPath) }

        let fetcher = UsageFetcher(environment: ["CODEX_CLI_PATH": stubCLIPath])
        let credits = try await fetcher.loadLatestCredits()

        #expect(credits.remaining == 0)
    }

    @Test
    func `CLI credits load from RPC response without usage windows`() async throws {
        let stubCLIPath = try self.makeCreditsOnlyStubCodexCLI()
        defer { try? FileManager.default.removeItem(atPath: stubCLIPath) }

        let fetcher = UsageFetcher(environment: ["CODEX_CLI_PATH": stubCLIPath])
        let credits = try await fetcher.loadLatestCredits()

        #expect(credits.remaining == 21)
        await #expect(throws: UsageError.noRateLimitsFound) {
            _ = try await fetcher.loadLatestUsage()
        }
    }

    @Test
    func `CLI usage fails when RPC body recovery misses session lane`() async throws {
        let stubCLIPath = try self.makeDecodeMismatchStubCodexCLI(message: Self.partialDecodeBodyMessage)
        defer { try? FileManager.default.removeItem(atPath: stubCLIPath) }

        let fetcher = UsageFetcher(environment: ["CODEX_CLI_PATH": stubCLIPath])

        do {
            _ = try await fetcher.loadLatestUsage()
            Issue.record("Expected RPC failure without PTY fallback")
        } catch {
            #expect(error.localizedDescription.contains("Codex connection failed"))
        }
    }

    @Test
    func `hung CLI RPC rate limits request times out within budget`() async throws {
        let stubCLIPath = try self.makeHungRateLimitsStubCodexCLI()
        defer { try? FileManager.default.removeItem(atPath: stubCLIPath) }

        let fetcher = UsageFetcher(
            environment: ["CODEX_CLI_PATH": stubCLIPath],
            initializeTimeoutSeconds: 2.0,
            requestTimeoutSeconds: 0.2)

        let started = Date()
        do {
            _ = try await fetcher.loadLatestUsage()
            Issue.record("Expected hung Codex RPC usage request to time out")
        } catch let error as RPCWireError {
            guard case let .timeout(method) = error else {
                Issue.record("Expected RPC timeout, got \(error)")
                return
            }
            #expect(method == "account/rateLimits/read")
        } catch {
            Issue.record("Expected RPCWireError.timeout, got \(type(of: error)): \(error)")
        }

        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 3.0, "Hung RPC request must fail fast, took \(elapsed)s")
    }

    @Test
    func `repeated hung CLI RPC requests stay bounded`() async throws {
        let stubCLIPath = try self.makeHungRateLimitsStubCodexCLI()
        defer { try? FileManager.default.removeItem(atPath: stubCLIPath) }

        let fetcher = UsageFetcher(
            environment: ["CODEX_CLI_PATH": stubCLIPath],
            initializeTimeoutSeconds: 2.0,
            requestTimeoutSeconds: 0.2)

        for attempt in 1...2 {
            let started = Date()
            do {
                _ = try await fetcher.loadLatestCredits()
                Issue.record("Expected hung Codex RPC credits request \(attempt) to time out")
            } catch let error as RPCWireError {
                guard case .timeout = error else {
                    Issue.record("Expected RPC timeout on attempt \(attempt), got \(error)")
                    return
                }
            } catch {
                Issue.record("Expected RPCWireError.timeout on attempt \(attempt), got \(type(of: error)): \(error)")
            }

            let elapsed = Date().timeIntervalSince(started)
            #expect(elapsed < 3.0, "Hung RPC request \(attempt) must fail fast, took \(elapsed)s")
        }
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

    private static let creditsOnlyDecodeMismatchBodyMessage = """
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
        }
      },
      "credits": {
        "has_credits": true,
        "unlimited": false,
        "overage_limit_reached": false,
        "balance": "14.5"
      }
    }
    """

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
            sys.stderr.write("unexpected non app-server Codex invocation\\n")
            sys.exit(92)
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-fallback-stub-\(UUID().uuidString)", isDirectory: false)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func makeCreditsOnlyStubCodexCLI() throws -> String {
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
                        "result": {
                            "rateLimits": {
                                "credits": {
                                    "hasCredits": True,
                                    "unlimited": False,
                                    "balance": "21"
                                }
                            }
                        }
                    }
                elif method == "account/read":
                    payload = {
                        "id": identifier,
                        "result": {
                            "account": {
                                "type": "chatgpt",
                                "email": "stub@example.com",
                                "planType": "pro"
                            },
                            "requiresOpenaiAuth": False
                        }
                    }
                else:
                    payload = {"id": identifier, "result": {}}

                print(json.dumps(payload), flush=True)
        else:
            sys.stderr.write("unexpected non app-server Codex invocation\\n")
            sys.exit(92)
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-credits-only-stub-\(UUID().uuidString)", isDirectory: false)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func makeHungRateLimitsStubCodexCLI() throws -> String {
        let script = """
        #!/bin/sh
        case " $* " in
          *" app-server "*) ;;
          *) printf '%s\\n' "unexpected non app-server Codex invocation" >&2; exit 92 ;;
        esac

        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialized"'*|*'"method": "initialized"'*)
              ;;
            *'"method":"initialize"'*|*'"method": "initialize"'*)
              printf '%s\\n' '{"id":1,"result":{}}'
              ;;
            *'"method":"account/rateLimits/read"'*|*'"method": "account/rateLimits/read"'*)
              sleep 30
              ;;
            *)
              printf '%s\\n' '{"id":1,"result":{}}'
              ;;
          esac
        done
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-hung-stub-\(UUID().uuidString)", isDirectory: false)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
}
