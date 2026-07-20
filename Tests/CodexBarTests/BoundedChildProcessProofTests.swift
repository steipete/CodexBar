import Foundation
import Testing
@testable import CodexBarCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite(.serialized)
struct BoundedChildProcessProofTests {
    @Test
    func `synthetic PTY child overflow propagates and cleans up the process`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarBoundedProcessProof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pidURL = directory.appendingPathComponent("child.pid")
        let scriptURL = directory.appendingPathComponent("overflow-child.sh")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$$" > "$CODEXBAR_PROOF_PID_FILE"
        /usr/bin/yes x | /usr/bin/head -c 1100000
        /bin/sleep 30
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        var environment = ProcessInfo.processInfo.environment
        environment["CODEXBAR_PROOF_PID_FILE"] = pidURL.path
        let runner = TTYCommandRunner()
        do {
            _ = try runner.run(
                binary: scriptURL.path,
                send: "",
                options: .init(timeout: 10, baseEnvironment: environment, initialDelay: 0))
            Issue.record("Expected the synthetic child to exceed the PTY output limit")
        } catch TTYCommandRunner.Error.outputTooLarge {
            // Expected: the production runner propagated the bounded-output error.
        } catch {
            Issue.record("Unexpected overflow error: \(error)")
        }

        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(pid_t(pidText))
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test
    func `synthetic Grok RPC child returns a normal framed response`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarBoundedRPCProof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let scriptURL = directory.appendingPathComponent("grok-proof.sh")
        let script = """
        #!/bin/sh
        IFS= read -r initialize_request
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
        IFS= read -r billing_request
        printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"monthlyLimit":{"val":100},"usage":{"totalUsed":{"val":25}}}}'
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let client = try GrokRPCClient(
            executable: scriptURL.path,
            arguments: [],
            environment: [
                "PATH": "/usr/bin:/bin",
                "GROK_CLI_PATH": scriptURL.path,
            ],
            initializeTimeoutSeconds: 2,
            requestTimeoutSeconds: 2)
        defer { client.shutdown() }

        try await client.initialize()
        let billing = try await client.fetchBilling()

        #expect(billing.monthlyLimit?.val == 100)
        #expect(billing.usage?.totalUsed?.val == 25)
        #expect(billing.monthlyUsedPercent == 25)
    }

    @Test
    func `synthetic Grok RPC child overflow terminates the process`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarBoundedRPCOverflowProof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pidURL = directory.appendingPathComponent("child.pid")
        let scriptURL = directory.appendingPathComponent("grok-overflow-proof.sh")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$$" > "$CODEXBAR_PROOF_PID_FILE"
        IFS= read -r initialize_request
        block='xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
        while :; do
            printf '%s' "$block"
        done
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
            initializeTimeoutSeconds: 10,
            requestTimeoutSeconds: 2)
        defer { client.shutdown() }

        let start = ContinuousClock.now
        do {
            try await client.initialize()
            Issue.record("Expected the oversized Grok response to close the stream")
        } catch let GrokRPCError.malformed(message) {
            #expect(message == "grok agent stdio closed stdout")
        } catch {
            Issue.record("Unexpected Grok overflow error: \(error)")
        }
        #expect(start.duration(to: .now) < .seconds(5))

        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(pid_t(pidText))
        let deadline = Date().addingTimeInterval(2)
        while kill(pid, 0) == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }
}
