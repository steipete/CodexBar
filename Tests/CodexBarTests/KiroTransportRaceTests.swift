import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct KiroTransportRaceTests {
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

        let snapshot = try await KiroStatusProbe(
            cliBinaryResolver: { cliURL.path },
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
                printf 'Estimated Usage | resets on 2026-06-01 | KIRO FREE\n'
                printf 'Credits (49 of 50 covered in plan)\n'
                printf '████████████████████ 98%%\n'
                exit 91
              fi
              sleep 1
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

        let snapshot = try await KiroStatusProbe(
            cliBinaryResolver: { cliURL.path },
            usageProbeTimeout: 2,
            pipeTimeoutCap: 0.2).fetch()

        #expect(snapshot.creditsUsed == 12.50)
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
