import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct KiroTransportRaceTests {
    @Test
    func `accepted transport result after the shared deadline is rejected`() {
        let output = """
        Estimated Usage | resets on 2026-06-01 | KIRO FREE
        Credits (12.50 of 50 covered in plan)
        ████████████████████ 25%
        """
        let deadline = ContinuousClock().now

        #expect {
            try KiroStatusProbe.ensureAcceptedResultBeforeDeadline(
                output: output,
                deadline: deadline,
                now: deadline.advanced(by: .nanoseconds(1)))
        } throws: { error in
            guard case KiroStatusProbeError.timeout = error else { return false }
            return true
        }
    }

    @Test
    func `empty nonzero pipe exit falls back to PTY`() async throws {
        let cliURL = try self.makeCLI(
            """
            #!/bin/sh
            if [ ! -t 1 ]; then
              exit 42
            fi
            if [ "$1" = "whoami" ]; then
              printf 'Logged in with Google\nEmail: person@example.com\n'
              exit 0
            fi
            if [ "$1" = "chat" ] && [ "$3" = "/usage" ]; then
              printf 'Estimated Usage | resets on 2026-06-01 | KIRO FREE\n'
              printf 'Credits (12.50 of 50 covered in plan)\n'
              printf '████████████████████ 25%%\n'
              exit 0
            fi
            if [ "$1" = "chat" ] && [ "$3" = "/context" ]; then
              exit 0
            fi
            exit 1
            """)
        defer { try? FileManager.default.removeItem(at: cliURL.deletingLastPathComponent()) }

        let snapshot = try await KiroProcessTestSupport.makeFunctionalProbe(
            cliURL: cliURL,
            pipeTimeoutCap: 0.2).fetch()

        #expect(snapshot.planName == "KIRO FREE")
        #expect(snapshot.accountEmail == "person@example.com")
    }

    @Test
    func `failed PTY cannot preempt a valid slow pipe`() async throws {
        let cliURL = try self.makeCLI(
            """
            #!/bin/sh
            if [ "$1" = "whoami" ]; then
              printf 'Logged in with Google\nEmail: person@example.com\n'
              exit 0
            fi
            if [ "$1" = "chat" ] && [ "$3" = "/usage" ]; then
              if [ -t 1 ]; then
                printf '%s\n' "$$" > "${0%/*}/pty.pid"
                printf 'Estimated Usage | resets on 2026-06-01 | KIRO FREE\n'
                printf 'Credits (49 of 50 covered in plan)\n'
                printf '████████████████████ 98%%\n'
                exit 91
              fi
              printf '%s\n' "$$" > "${0%/*}/pipe.ready"
              attempts=0
              while [ ! -e "${0%/*}/pipe.release" ]; do
                attempts=$((attempts + 1))
                [ "$attempts" -lt 2000 ] || exit 92
                sleep 0.01
              done
              printf 'Estimated Usage | resets on 2026-06-01 | KIRO FREE\n'
              printf 'Credits (12.50 of 50 covered in plan)\n'
              printf '████████████████████ 25%%\n'
              exit 0
            fi
            if [ "$1" = "chat" ] && [ "$3" = "/context" ]; then
              exit 0
            fi
            exit 1
            """)
        defer { try? FileManager.default.removeItem(at: cliURL.deletingLastPathComponent()) }

        let root = cliURL.deletingLastPathComponent()
        let registry = KiroTestProcessRegistry()
        defer { registry.terminateAll() }
        let probe = KiroProcessTestSupport.makeFunctionalProbe(
            cliURL: cliURL,
            pipeTimeoutCap: 0.2,
            processRegistry: registry)
        let task = Task { try await probe.fetch() }

        do {
            let pipePID = try await KiroProcessTestSupport.waitForPID(in: root.appendingPathComponent("pipe.ready"))
            try #require(registry.isRegistered(pipePID))
            let ptyPID = try await KiroProcessTestSupport.waitForPID(in: root.appendingPathComponent("pty.pid"))
            // Observe process exit before releasing the pipe; this does not certify PTY event consumption.
            try await KiroProcessTestSupport.waitForExit(
                of: ptyPID,
                timeout: KiroProcessTestSupport.fixtureSetupTimeout,
                description: "the failed PTY fixture to exit before releasing valid pipe output")
            try KiroProcessTestSupport.touch(root.appendingPathComponent("pipe.release"))

            let snapshot = try await task.value
            #expect(snapshot.creditsUsed == 12.50)
            #expect(registry.activePIDs().isEmpty)
            try await KiroProcessTestSupport.waitForExit(
                of: Array(registry.observedPIDs()),
                timeout: KiroProcessTestSupport.fixtureSetupTimeout,
                description: "the owned pipe fixtures to exit")
        } catch {
            task.cancel()
            registry.terminateAll()
            // Joining fetch also joins the PTY runner's scoped cancellation cleanup before removing the fixture.
            _ = try? await task.value
            throw error
        }
    }

    @Test
    func `pending failed PTY cannot escape the shared deadline`() async throws {
        let cliURL = try self.makeCLI(
            """
            #!/bin/sh
            if [ "$1" = "whoami" ]; then
              printf 'Logged in with Google\nEmail: person@example.com\n'
              exit 0
            fi
            if [ "$1" = "chat" ] && [ "$3" = "/usage" ]; then
              if [ -t 1 ]; then
                exit 91
              fi
              sleep 5
              exit 0
            fi
            exit 0
            """)
        defer { try? FileManager.default.removeItem(at: cliURL.deletingLastPathComponent()) }

        let probe = KiroStatusProbe(
            cliBinaryResolver: { cliURL.path },
            usageProbeTimeout: 0.6,
            pipeTimeoutCap: 0.1)

        await #expect {
            try await probe.fetch()
        } throws: { error in
            guard case KiroStatusProbeError.timeout = error else { return false }
            return true
        }
    }

    private func makeCLI(_ script: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-kiro-race-\(UUID().uuidString)", isDirectory: true)
        let cliURL = root.appendingPathComponent("kiro-cli")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try script.write(to: cliURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliURL.path)
        return cliURL
    }
}
