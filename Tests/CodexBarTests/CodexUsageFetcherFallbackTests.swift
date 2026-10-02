import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized, .timeLimit(.minutes(1)), RPCFixtureDeadlineControl())
struct CodexUsageFetcherFallbackTests {
    @Test
    func `missing CLI binary reports install guidance instead of not running`() async throws {
        let fetcher = UsageFetcher(
            environment: [:],
            initializeTimeoutSeconds: 0.1,
            requestTimeoutSeconds: 0.1,
            codexExecutableResolver: { _, _ in nil })

        do {
            _ = try await fetcher.loadLatestCLIAccountSnapshot()
            Issue.record("Expected missing Codex CLI to throw")
        } catch CodexStatusProbeError.codexNotInstalled {
            let message = CodexStatusProbeError.codexNotInstalled.localizedDescription
            #expect(message.contains("Codex CLI missing"))
            #expect(!message.contains("Codex not running"))
        } catch {
            Issue.record("Expected CodexStatusProbeError.codexNotInstalled, got \(type(of: error)): \(error)")
        }
    }

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

        let fetcher = self.makeStubUsageFetcher(stubCLIPath)
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

        let fetcher = self.makeStubUsageFetcher(stubCLIPath)
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

        let fetcher = self.makeStubUsageFetcher(stubCLIPath)
        let credits = try await fetcher.loadLatestCredits()

        #expect(credits.remaining == 0)
    }

    @Test
    func `CLI credits load from RPC response without usage windows`() async throws {
        let stubCLIPath = try self.makeCreditsOnlyStubCodexCLI()
        defer { try? FileManager.default.removeItem(atPath: stubCLIPath) }

        let fetcher = self.makeStubUsageFetcher(stubCLIPath)
        let credits = try await fetcher.loadLatestCredits()

        #expect(credits.remaining == 21)
        await #expect(throws: UsageError.noRateLimitsFound) {
            _ = try await fetcher.loadLatestUsage()
        }
    }

    @Test
    func `CLI usage starts app server with current read-only noninteractive arguments`() async throws {
        let stubCLIPath = try self.makePlanOnlyStubCodexCLI()
        defer { try? FileManager.default.removeItem(atPath: stubCLIPath) }

        let fetcher = self.makeStubUsageFetcher(stubCLIPath, useDefaultArguments: true)
        let snapshot = try await fetcher.loadLatestUsage()

        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.accountEmail(for: .codex) == "stub@example.com")
        #expect(snapshot.loginMethod(for: .codex) == "pro")
        #expect(snapshot.rateLimitsUnavailable(for: .codex))
    }

    @Test
    func `CLI plan and credits response without usage windows keeps unavailable limits`() async throws {
        let stubCLIPath = try self.makePlanOnlyStubCodexCLI(includeCredits: true)
        defer { try? FileManager.default.removeItem(atPath: stubCLIPath) }

        let fetcher = self.makeStubUsageFetcher(stubCLIPath)
        let snapshot = try await fetcher.loadLatestCLIAccountSnapshot()

        #expect(snapshot.usage?.primary == nil)
        #expect(snapshot.usage?.secondary == nil)
        #expect(snapshot.usage?.rateLimitsUnavailable(for: .codex) == true)
        #expect(snapshot.credits?.remaining == 21)
    }

    @Test(arguments: ["pro", "plus", "", "  ", nil] as [String?], [false, true])
    func `CLI fresh usage plan takes precedence over cached account plan`(
        usagePlan: String?,
        includeWindows: Bool) async throws
    {
        let stubCLIPath = try self.makePlanOnlyStubCodexCLI(
            usagePlan: usagePlan,
            accountPlan: "plus",
            includeWindows: includeWindows)
        defer { try? FileManager.default.removeItem(atPath: stubCLIPath) }

        let snapshot = try await self.makeStubUsageFetcher(stubCLIPath).loadLatestCLIAccountSnapshot()

        let expectedPlan = usagePlan == "pro" ? "pro" : "plus"
        #expect(snapshot.identity?.loginMethod == expectedPlan)
        #expect(snapshot.usage?.loginMethod(for: .codex) == expectedPlan)
        #expect(snapshot.usage?.accountEmail(for: .codex) == "stub@example.com")
        #expect(snapshot.usage?.primary?.usedPercent == (includeWindows ? 12 : nil))
        #expect(snapshot.usage?.rateLimitsUnavailable(for: .codex) == !includeWindows)
    }

    @Test
    func `CLI usage fails when RPC body recovery misses session lane`() async throws {
        let stubCLIPath = try self.makeDecodeMismatchStubCodexCLI(message: Self.partialDecodeBodyMessage)
        defer { try? FileManager.default.removeItem(atPath: stubCLIPath) }

        let fetcher = self.makeStubUsageFetcher(stubCLIPath)

        do {
            _ = try await fetcher.loadLatestUsage()
            Issue.record("Expected RPC failure without PTY fallback")
        } catch {
            #expect(error.localizedDescription.contains("Codex connection failed"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `hung CLI RPC rate limits request reports its timeout`() async throws {
        let stubCLIPath = try self.makeHungRateLimitsStubCodexCLI()
        let requestPath = stubCLIPath + ".requests"
        defer {
            try? FileManager.default.removeItem(atPath: stubCLIPath)
            try? FileManager.default.removeItem(atPath: requestPath)
        }

        let fetcher = self.makeStubUsageFetcher(stubCLIPath, requestTimeoutSeconds: 0.01)

        do {
            _ = try await self.withHungRequestDeadline(requestPath: requestPath) {
                try await fetcher.loadLatestUsage()
            }
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

        #expect(try String(contentsOfFile: requestPath, encoding: .utf8) == "account/rateLimits/read\n")
    }

    @Test(.timeLimit(.minutes(1)))
    func `repeated hung CLI RPC requests report their timeouts`() async throws {
        let stubCLIPath = try self.makeHungRateLimitsStubCodexCLI()
        let requestPath = stubCLIPath + ".requests"
        defer {
            try? FileManager.default.removeItem(atPath: stubCLIPath)
            try? FileManager.default.removeItem(atPath: requestPath)
        }

        let fetcher = self.makeStubUsageFetcher(stubCLIPath, requestTimeoutSeconds: 0.01)

        for attempt in 1...2 {
            do {
                _ = try await self.withHungRequestDeadline(requestPath: requestPath, attempt: attempt) {
                    try await fetcher.loadLatestCredits()
                }
                Issue.record("Expected hung Codex RPC credits request \(attempt) to time out")
            } catch let error as RPCWireError {
                guard case let .timeout(method) = error else {
                    Issue.record("Expected RPC timeout on attempt \(attempt), got \(error)")
                    return
                }
                #expect(method == "account/rateLimits/read")
            } catch {
                Issue.record("Expected RPCWireError.timeout on attempt \(attempt), got \(type(of: error)): \(error)")
            }

            #expect(try String(contentsOfFile: requestPath, encoding: .utf8)
                == String(repeating: "account/rateLimits/read\n", count: attempt))
        }
    }

    @Test(arguments: ["account/rateLimits/read", "account\\/rateLimits\\/read"])
    func `hung fixture recognizes both JSON slash encodings`(method: String) async throws {
        let stubCLIPath = try self.makeHungRateLimitsStubCodexCLI()
        let requestPath = stubCLIPath + ".requests"
        defer {
            try? FileManager.default.removeItem(atPath: stubCLIPath)
            try? FileManager.default.removeItem(atPath: requestPath)
        }
        let stdin = RPCChildProcessInput()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [stubCLIPath, "app-server"]
        process.environment = ["CODEXBAR_TEST_RPC_REQUEST_PATH": requestPath]
        process.standardInput = stdin.pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { RPCChildProcessTeardown.terminate(process: process, stdin: stdin) }
        try stdin.write(Data("{\"id\":2,\"method\":\"\(method)\"}\n".utf8))

        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while (try? String(contentsOfFile: requestPath, encoding: .utf8)) != "account/rateLimits/read\n",
              ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try String(contentsOfFile: requestPath, encoding: .utf8) == "account/rateLimits/read\n")
        #expect(process.isRunning)
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

    private func withHungRequestDeadline<Value: Sendable>(
        requestPath: String,
        attempt: Int = 1,
        operation: @Sendable () async throws -> Value) async throws -> Value
    {
        let deadline: @Sendable (TimeInterval) async throws -> Void = { seconds in
            let expected = String(repeating: "account/rateLimits/read\n", count: attempt)
            while (try? String(contentsOfFile: requestPath, encoding: .utf8)) != expected {
                try await Task.sleep(for: .milliseconds(20))
            }
            // Exercise the real timer only after the child acknowledges the deliberately unanswered request.
            try await Task.sleep(for: .seconds(seconds))
        }
        return try await RPCRequestTimeout.$sleep.withValue(deadline) {
            try await operation()
        }
    }

    private func makeStubUsageFetcher(
        _ stubCLIPath: String,
        requestTimeoutSeconds: TimeInterval = 30,
        useDefaultArguments: Bool = false) -> UsageFetcher
    {
        let environment = [
            "PATH": "/usr/bin:/bin",
            "CODEX_CLI_PATH": stubCLIPath,
            "CODEXBAR_TEST_RPC_REQUEST_PATH": stubCLIPath + ".requests",
        ]
        let resolve: CodexExecutableResolver = { _, _ in
            CodexExecutableResolution(executable: useDefaultArguments ? stubCLIPath : "/bin/sh", loginPATH: [])
        }
        if useDefaultArguments {
            // This case must exercise the fetcher's defaults, without supplying its own argument list.
            return UsageFetcher(
                environment: environment,
                initializeTimeoutSeconds: 20,
                requestTimeoutSeconds: requestTimeoutSeconds,
                codexExecutableResolver: resolve)
        }
        return UsageFetcher(
            environment: environment,
            initializeTimeoutSeconds: 20.0,
            requestTimeoutSeconds: requestTimeoutSeconds,
            codexArguments: [stubCLIPath, "-s", "read-only", "-a", "never", "app-server"],
            codexExecutableResolver: resolve)
    }

    private func makeDecodeMismatchStubCodexCLI(
        message: String = Self.decodeMismatchBodyMessage) throws -> String
    {
        try self.makeStubCodexCLI(rateLimitsResponse: ["error": ["message": message]], accountPlan: "prolite")
    }

    private func makePlanOnlyStubCodexCLI(
        includeCredits: Bool = false,
        usagePlan: String? = "pro",
        accountPlan: String = "pro",
        includeWindows: Bool = false) throws -> String
    {
        var limits: [String: Any] = ["planType": usagePlan.map { $0 as Any } ?? NSNull()]
        if includeCredits {
            limits["credits"] = ["hasCredits": true, "unlimited": false, "balance": "21"]
        }
        if includeWindows {
            limits["primary"] = ["usedPercent": 12, "windowDurationMins": 300]
        }
        return try self.makeStubCodexCLI(
            rateLimitsResponse: ["result": ["rateLimits": limits]], accountPlan: accountPlan)
    }

    private func makeCreditsOnlyStubCodexCLI() throws -> String {
        try self.makeStubCodexCLI(rateLimitsResponse: ["result": ["rateLimits": [
            "credits": ["hasCredits": true, "unlimited": false, "balance": "21"],
        ]]], accountPlan: "pro")
    }

    private func makeStubCodexCLI(rateLimitsResponse: [String: Any], accountPlan: String) throws -> String {
        func shellJSON(_ value: [String: Any]) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            let json = try #require(String(data: data, encoding: .utf8))
            // Drop the opening brace so the shell can prepend the request's actual ID.
            return json.dropFirst()
                .replacingOccurrences(of: "'", with: "'\"'\"'")
        }
        let limits = try shellJSON(rateLimitsResponse)
        let account = try shellJSON(["result": [
            "account": ["type": "chatgpt", "email": "stub@example.com", "planType": accountPlan],
            "requiresOpenaiAuth": false,
        ]])
        let script = """
        #!/bin/sh
        if [ "$#" != 5 ] || [ "$1 $2 $3 $4 $5" != '-s read-only -a never app-server' ]; then
          printf '%s\\n' 'unexpected Codex arguments' >&2
          exit 64
        fi
        while IFS= read -r line; do
          identifier=${line#*'"id"'}
          identifier=${identifier#*:}
          identifier=${identifier#"${identifier%%[![:space:]]*}"}
          identifier=${identifier%%[!0-9]*}
          case "$line" in
            *'"initialized"'*) ;;
            *'"initialize"'*) printf '{"id":%s,"result":{}}\\n' "$identifier" ;;
            *'"account/rateLimits/read"'*|*'"account\\/rateLimits\\/read"'*)
              printf '{"id":%s,%s\\n' "$identifier" '\(limits)' ;;
            *'"account/read"'*|*'"account\\/read"'*)
              printf '{"id":%s,%s\\n' "$identifier" '\(account)' ;;
            *) printf '%s\\n' 'unexpected RPC method' >&2; exit 65 ;;
          esac
        done
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-fallback-stub-\(UUID().uuidString)")
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
            *'"account/rateLimits/read"'*|*'"account\\/rateLimits\\/read"'*)
              printf '%s\\n' 'account/rateLimits/read' >> "$CODEXBAR_TEST_RPC_REQUEST_PATH"
              # Keep the request unanswered until the RPC client closes stdin.
              while IFS= read -r ignored; do :; done
              exit 0
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

/// Functional fixtures finish through RPC replies; timeout cases explicitly advance their own deadline.
private struct RPCFixtureDeadlineControl: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool {
        true
    }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void) async throws
    {
        let suspended: @Sendable (TimeInterval) async throws -> Void = { _ in
            let pending = AsyncStream<Void> { _ in }
            for await _ in pending {}
            try Task.checkCancellation()
        }
        try await RPCRequestTimeout.$sleep.withValue(suspended) {
            try await function()
        }
    }
}
