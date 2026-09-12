import Foundation
import Testing
@testable import CodexBarCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite(.serialized)
struct RPCChildProcessTeardownTests {
    @Test
    func `RPC stdin writes after child teardown fail without aborting`() throws {
        let stdin = RPCChildProcessInput()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.standardInput = stdin.pipe
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()

        RPCChildProcessTeardown.terminate(process: process, stdin: stdin)

        #expect(throws: (any Error).self) {
            try stdin.write(Data("{\"id\":1}\n".utf8))
        }
        stdin.close()
    }

    @Test
    func `RPC stdin writes to an unexpectedly exited child throw without aborting`() throws {
        let stdin = RPCChildProcessInput()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.standardInput = stdin.pipe
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()

        process.terminate()
        process.waitUntilExit()
        defer { stdin.close() }

        #expect(throws: (any Error).self) {
            try stdin.write(Data("{\"id\":1}\n".utf8))
        }
    }

    @Test
    func `Codex RPC reports a normal failure when its child closes stdin`() async throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-closed-stdin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let script = """
        #!/usr/bin/python3 -S
        import os
        import sys

        sys.stdin.readline()
        os.close(0)
        print('{"id":1,"result":{}}', flush=True)
        os._exit(0)
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let fetcher = UsageFetcher(
            environment: ["CODEX_CLI_PATH": scriptURL.path],
            initializeTimeoutSeconds: 5,
            requestTimeoutSeconds: 2,
            codexExecutableResolver: { _, _ in
                CodexExecutableResolution(executable: scriptURL.path, loginPATH: [])
            })

        let error = await #expect(throws: RPCWireError.self) {
            _ = try await fetcher.loadLatestCLIAccountSnapshot()
        }
        guard case let .requestFailed(message) = error else {
            Issue.record("Expected a normal RPC request failure, got \(String(describing: error))")
            return
        }
        #expect(message.contains("stdin closed"))
    }

    @Test
    func `Grok RPC requests after child shutdown fail without aborting`() async throws {
        let client = try GrokRPCClient(
            executable: "/bin/cat",
            arguments: [],
            environment: [
                "PATH": "/usr/bin:/bin",
                "GROK_CLI_PATH": "/bin/cat",
            ],
            initializeTimeoutSeconds: 5,
            requestTimeoutSeconds: 2)

        client.shutdown()

        let error = await #expect(throws: GrokRPCError.self) {
            try await client.initialize()
        }
        guard case let .requestFailed(message) = error else {
            Issue.record("Expected a normal Grok request failure, got \(String(describing: error))")
            return
        }
        #expect(message.contains("stdin closed"))
    }

    @Test
    func `Codex RPC shutdown kills an app-server child that ignores SIGTERM`() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let scriptURL = temporaryDirectory.appendingPathComponent("codex-stub-\(UUID().uuidString)")
        let pidURL = temporaryDirectory.appendingPathComponent("codex-stub-pid-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: pidURL)
        }

        let script = """
        #!/bin/sh
        case " $* " in *" app-server "*) ;; *) exit 92 ;; esac
        printf '%s\n' "$$" > "$CODEXBAR_PROOF_PID_FILE"
        trap '' TERM
        while IFS= read -r line; do
          case "$line" in
            *'"initialized"'*) ;;
            *'"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
            *'"account/rateLimits/read"'*|*'"account\\/rateLimits\\/read"'*)
              printf '%s\n' '{"id":2,"result":{"rateLimits":{"planType":"pro"}}}'
              ;;
            *'"account/read"'*|*'"account\\/read"'*)
              printf '%s%s\n' \
                '{"id":3,"result":{"account":{"type":"chatgpt","email":"stub@example.com",' \
                '"planType":"pro"},"requiresOpenaiAuth":false}}'
              ;;
            *) printf '%s\n' '{"id":1,"result":{}}' ;;
          esac
        done
        while :; do sleep 0.2; done
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let fetcher = UsageFetcher(
            environment: [
                "CODEX_CLI_PATH": scriptURL.path,
                "CODEXBAR_PROOF_PID_FILE": pidURL.path,
            ],
            initializeTimeoutSeconds: 20.0,
            requestTimeoutSeconds: 3.0,
            codexExecutableResolver: { _, _ in
                CodexExecutableResolution(executable: scriptURL.path, loginPATH: [])
            })

        _ = try await fetcher.loadLatestCLIAccountSnapshot()

        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(pid_t(pidText))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while kill(pid, 0) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test
    func `Grok RPC shutdown kills a stdio child that ignores SIGTERM`() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let scriptURL = temporaryDirectory.appendingPathComponent("grok-stub-\(UUID().uuidString)")
        let pidURL = temporaryDirectory.appendingPathComponent("grok-stub-pid-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: pidURL)
        }

        let script = """
        #!/bin/sh
        printf '%s\n' "$$" > "$CODEXBAR_PROOF_PID_FILE"
        trap '' TERM
        while IFS= read -r line; do
          case "$line" in
            *'"initialize"'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}' ;;
            *) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}' ;;
          esac
        done
        while :; do sleep 0.2; done
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let client = try GrokRPCClient(
            executable: scriptURL.path,
            arguments: [],
            environment: [
                "PATH": "/usr/bin:/bin",
                "GROK_CLI_PATH": scriptURL.path,
                "CODEXBAR_PROOF_PID_FILE": pidURL.path,
            ],
            initializeTimeoutSeconds: 5,
            requestTimeoutSeconds: 2)
        try await client.initialize()

        let start = ContinuousClock.now
        client.shutdown()
        let elapsed = start.duration(to: .now)
        #expect(elapsed < .seconds(3))

        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(pid_t(pidText))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while kill(pid, 0) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }
}
