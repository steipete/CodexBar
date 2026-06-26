import Foundation
import Testing
@testable import CodexBarCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private func waitForFile(_ url: URL) async throws {
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: url.path) {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Suite(.serialized)
struct KiroStatusProbeTests {
    @Test
    func `fetch returns usage when account probe times out`() async throws {
        let cliURL = try self.makeCLI(
            """
            #!/bin/sh
            if [ "$1" = "whoami" ]; then
              sleep 5
              printf 'Logged in with Google\\nEmail: person@example.com\\n'
              exit 0
            fi

            if [ "$1" = "chat" ] && [ "$3" = "/usage" ]; then
              printf 'Estimated Usage | resets on 2026-06-01 | KIRO FREE\\n'
              printf 'Credits (12.50 of 50 covered in plan)\\n'
              printf '████████████████████ 25%%\\n'
              exit 0
            fi

            if [ "$1" = "chat" ] && [ "$3" = "/context" ]; then
              exit 0
            fi

            exit 1
            """)
        defer { try? FileManager.default.removeItem(at: cliURL.deletingLastPathComponent()) }

        let probe = KiroStatusProbe(cliBinaryResolver: { cliURL.path }, accountProbeTimeout: 0.2)
        let snapshot = try await probe.fetch()

        #expect(snapshot.planName == "KIRO FREE")
        #expect(snapshot.creditsUsed == 12.50)
        #expect(snapshot.accountEmail == nil)
        #expect(snapshot.authMethod == nil)
    }

    @Test
    func `fetch preserves account info when account probe succeeds`() async throws {
        let cliURL = try self.makeCLI(
            """
            #!/bin/sh
            if [ "$1" = "whoami" ]; then
              printf 'Logged in with Google\\nEmail: person@example.com\\n'
              exit 0
            fi

            if [ "$1" = "chat" ] && [ "$3" = "/usage" ]; then
              printf 'Estimated Usage | resets on 2026-06-01 | KIRO FREE\\n'
              printf 'Credits (12.50 of 50 covered in plan)\\n'
              printf '████████████████████ 25%%\\n'
              exit 0
            fi

            if [ "$1" = "chat" ] && [ "$3" = "/context" ]; then
              exit 0
            fi

            exit 1
            """)
        defer { try? FileManager.default.removeItem(at: cliURL.deletingLastPathComponent()) }

        let probe = KiroStatusProbe(cliBinaryResolver: { cliURL.path })
        let snapshot = try await probe.fetch()

        #expect(snapshot.accountEmail == "person@example.com")
        #expect(snapshot.authMethod == "Google")
    }

    @Test
    func `fetch rejects account markers from failed whoami`() async throws {
        let cliURL = try self.makeCLI(
            """
            #!/bin/sh
            if [ "$1" = "whoami" ]; then
              printf 'Logged in with Google\nEmail: person@example.com\n'
              exit 23
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

        let snapshot = try await KiroStatusProbe(cliBinaryResolver: { cliURL.path }).fetch()

        #expect(snapshot.accountEmail == nil)
        #expect(snapshot.authMethod == nil)
    }

    @Test
    func `fetch rejects valid-looking usage from failed command`() async throws {
        let cliURL = try self.makeCLI(
            """
            #!/bin/sh
            if [ "$1" = "whoami" ]; then
              printf 'Logged in with Google\nEmail: person@example.com\n'
              exit 0
            fi

            if [ "$1" = "chat" ] && [ "$3" = "/usage" ]; then
              printf 'Estimated Usage | resets on 2026-06-01 | KIRO FREE\n'
              printf 'Credits (12.50 of 50 covered in plan)\n'
              printf '████████████████████ 25%%\n'
              exit 23
            fi

            if [ "$1" = "chat" ] && [ "$3" = "/context" ]; then
              exit 0
            fi

            exit 1
            """)
        defer { try? FileManager.default.removeItem(at: cliURL.deletingLastPathComponent()) }

        let probe = KiroStatusProbe(cliBinaryResolver: { cliURL.path })
        await #expect {
            _ = try await probe.fetch()
        } throws: { error in
            guard case KiroStatusProbeError.cliFailed = error else { return false }
            return true
        }
    }

    @Test
    func `fetch preserves not logged in when usage fails without auth detail`() async throws {
        let cliURL = try self.makeCLI(
            """
            #!/bin/sh
            if [ "$1" = "whoami" ]; then
              printf 'Not logged in\\n'
              exit 1
            fi

            if [ "$1" = "chat" ] && [ "$3" = "/usage" ]; then
              exit 1
            fi

            if [ "$1" = "chat" ] && [ "$3" = "/context" ]; then
              exit 0
            fi

            exit 1
            """)
        defer { try? FileManager.default.removeItem(at: cliURL.deletingLastPathComponent()) }

        let probe = KiroStatusProbe(cliBinaryResolver: { cliURL.path })
        await #expect {
            _ = try await probe.fetch()
        } throws: { error in
            guard case KiroStatusProbeError.notLoggedIn = error else { return false }
            return true
        }
    }

    @Test
    func `fetch preserves not logged in when whoami idles after login marker`() async throws {
        let cliURL = try self.makeCLI(
            """
            #!/bin/sh
            if [ "$1" = "whoami" ]; then
              printf 'Not logged in\n'
              sleep 5
              exit 1
            fi

            if [ "$1" = "chat" ] && [ "$3" = "/usage" ]; then
              exit 1
            fi

            if [ "$1" = "chat" ] && [ "$3" = "/context" ]; then
              exit 0
            fi

            exit 1
            """)
        defer { try? FileManager.default.removeItem(at: cliURL.deletingLastPathComponent()) }

        let probe = KiroStatusProbe(cliBinaryResolver: { cliURL.path }, accountProbeTimeout: 2)
        await #expect {
            _ = try await probe.fetch()
        } throws: { error in
            guard case KiroStatusProbeError.notLoggedIn = error else { return false }
            return true
        }
    }

    @Test
    func `fetch preserves not logged in when usage output cannot be parsed`() async throws {
        let cliURL = try self.makeCLI(
            """
            #!/bin/sh
            if [ "$1" = "whoami" ]; then
              printf 'Not logged in\\n'
              exit 1
            fi

            if [ "$1" = "chat" ] && [ "$3" = "/usage" ]; then
              exit 0
            fi

            if [ "$1" = "chat" ] && [ "$3" = "/context" ]; then
              exit 0
            fi

            exit 1
            """)
        defer { try? FileManager.default.removeItem(at: cliURL.deletingLastPathComponent()) }

        let probe = KiroStatusProbe(cliBinaryResolver: { cliURL.path })
        await #expect {
            _ = try await probe.fetch()
        } throws: { error in
            guard case KiroStatusProbeError.notLoggedIn = error else { return false }
            return true
        }
    }

    @Test
    func `fetch cancellation during context probe is preserved`() async throws {
        let contextStarted = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-kiro-context-\(UUID().uuidString).started")
        let cliURL = try self.makeCLI(
            """
            #!/bin/sh
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
              : > '\(contextStarted.path)'
              trap '' TERM
              while true; do sleep 1; done
            fi

            exit 1
            """)
        defer {
            try? FileManager.default.removeItem(at: cliURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: contextStarted)
        }

        let probe = KiroStatusProbe(cliBinaryResolver: { cliURL.path })
        let task = Task { try await probe.fetch() }
        defer { task.cancel() }

        try await waitForFile(contextStarted)

        let cancelledAt = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(Date().timeIntervalSince(cancelledAt) < 4)
    }

    @Test
    func `fetch cancellation while waiting for account probe is preserved`() async throws {
        let accountStarted = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-kiro-account-\(UUID().uuidString).started")
        let cliURL = try self.makeCLI(
            """
            #!/bin/sh
            if [ "$1" = "whoami" ]; then
              : > '\(accountStarted.path)'
              trap '' TERM
              while true; do sleep 1; done
            fi

            if [ "$1" = "chat" ] && [ "$3" = "/usage" ]; then
              printf 'Estimated Usage | resets on 2026-06-01 | KIRO FREE\\n'
              printf 'Credits (12.50 of 50 covered in plan)\\n'
              printf '████████████████████ 25%%\\n'
              exit 0
            fi

            if [ "$1" = "chat" ] && [ "$3" = "/context" ]; then
              exit 0
            fi

            exit 1
            """)
        defer {
            try? FileManager.default.removeItem(at: cliURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: accountStarted)
        }

        let probe = KiroStatusProbe(cliBinaryResolver: { cliURL.path })
        let task = Task { try await probe.fetch() }
        defer { task.cancel() }

        try await waitForFile(accountStarted)

        let cancelledAt = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(Date().timeIntervalSince(cancelledAt) < 4)
    }

    @Test
    func `fetch returns promptly when usage helper spawns a detached child`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-kiro-pipe-\(UUID().uuidString)", isDirectory: true)
        let childPIDFile = root.appendingPathComponent("child.pid")
        let cliURL = root.appendingPathComponent("kiro-cli")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer {
            if let text = try? String(contentsOf: childPIDFile, encoding: .utf8),
               let childPID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                _ = kill(childPID, SIGKILL)
            }
        }

        let script = """
        #!/bin/bash
        set -e
        if [ "$1" = "whoami" ]; then
          printf 'Logged in with Google\\nEmail: person@example.com\\n'
          exit 0
        fi

        if [ "$1" = "chat" ] && [ "$3" = "/usage" ]; then
          /usr/bin/python3 -c '
        import os
        import subprocess
        import sys

        ready_read, ready_write = os.pipe()
        child = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import os,signal,sys,time; "
                "signal.signal(signal.SIGHUP, signal.SIG_IGN); "
                "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                "handle=open(sys.argv[1], \\\"w\\\"); handle.write(str(os.getpid())); handle.close(); "
                "os.write(int(sys.argv[2]), b\\\"1\\\"); os.close(int(sys.argv[2])); time.sleep(30)",
                os.environ["CODEXBAR_TEST_CHILD_PID_FILE"],
                str(ready_write),
            ],
            start_new_session=True,
            pass_fds=(ready_write,),
        )
        os.close(ready_write)
        if os.read(ready_read, 1) != b"1":
            raise RuntimeError("detached helper exited before signaling readiness")
        os.close(ready_read)
        '
          test -s "$CODEXBAR_TEST_CHILD_PID_FILE"
          printf 'Estimated Usage | resets on 2026-06-01 | KIRO FREE\\n'
          printf 'Credits (12.50 of 50 covered in plan)\\n'
          printf '████████████████████ 25%%\\n'
          exit 0
        fi

        if [ "$1" = "chat" ] && [ "$3" = "/context" ]; then
          exit 0
        fi

        exit 1
        """
        try script.write(to: cliURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliURL.path)

        let previousPIDFile = ProcessInfo.processInfo.environment["CODEXBAR_TEST_CHILD_PID_FILE"]
        setenv("CODEXBAR_TEST_CHILD_PID_FILE", childPIDFile.path, 1)
        defer {
            if let previousPIDFile {
                setenv("CODEXBAR_TEST_CHILD_PID_FILE", previousPIDFile, 1)
            } else {
                unsetenv("CODEXBAR_TEST_CHILD_PID_FILE")
            }
        }

        let probe = KiroStatusProbe(cliBinaryResolver: { cliURL.path })
        let start = Date()
        let snapshot = try await probe.fetch()
        let elapsed = Date().timeIntervalSince(start)

        let childPIDText = try String(contentsOf: childPIDFile, encoding: .utf8)
        let childPID = try #require(pid_t(childPIDText.trimmingCharacters(in: .whitespacesAndNewlines)))
        for _ in 0..<50 where kill(childPID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }

        // The PTY runner must return promptly and reap a detached helper that keeps the terminal open.
        #expect(snapshot.planName == "KIRO FREE")
        #expect(snapshot.creditsUsed == 12.50)
        #expect(elapsed < 8, "Kiro usage capture should return promptly even with a detached child, took \(elapsed)s")
        #expect(kill(childPID, 0) == -1)
    }

    @Test
    func `tty runner hard stops a process that ignores SIGTERM`() throws {
        let cliURL = try self.makeCLI(
            """
            #!/bin/sh
            trap '' TERM
            printf 'partial output\\n'
            while true; do sleep 1; done
            """)
        defer { try? FileManager.default.removeItem(at: cliURL.deletingLastPathComponent()) }

        let start = Date()
        let result = try TTYCommandRunner().run(
            binary: cliURL.path,
            send: "",
            options: .init(timeout: 2, idleTimeout: 0.1))
        let elapsed = Date().timeIntervalSince(start)

        #expect(result.completion == .idleTimeout)
        #expect(result.text.contains("partial output"))
        #expect(elapsed < 3, "Ignored SIGTERM should escalate to SIGKILL, took \(elapsed)s")
    }

    @Test
    func `tty runner kills a pipe holder that escapes the process group`() async throws {
        let childPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-kiro-escaped-\(UUID().uuidString).pid")
        let cliURL = try self.makeCLI(
            """
            #!/usr/bin/python3
            import subprocess
            import sys
            import time

            child = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)",
                ],
                start_new_session=True,
            )
            with open(sys.argv[1], "w") as handle:
                handle.write(str(child.pid))
            print("partial output", flush=True)
            time.sleep(30)
            """)
        defer {
            try? FileManager.default.removeItem(at: cliURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: childPIDFile)
        }

        let result = try TTYCommandRunner().run(
            binary: cliURL.path,
            send: "",
            options: .init(
                timeout: 2,
                idleTimeout: 0.1,
                extraArgs: [childPIDFile.path]))

        #expect(result.completion == .idleTimeout)
        #expect(result.text.contains("partial output"))

        let childPIDText = try String(contentsOf: childPIDFile, encoding: .utf8)
        let childPID = try #require(pid_t(childPIDText.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { _ = kill(childPID, SIGKILL) }

        let cleanupDeadline = Date().addingTimeInterval(1)
        while kill(childPID, 0) == 0, Date() < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(kill(childPID, 0) == -1)
    }

    @Test
    func `tty runner cleans a same group helper after normal exit`() throws {
        let childPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-kiro-normal-exit-\(UUID().uuidString).pid")
        let cliURL = try self.makeCLI(
            """
            #!/usr/bin/python3
            import os
            import signal
            import sys
            import time

            child = os.fork()
            if child == 0:
                os.close(1)
                os.close(2)
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                with open(sys.argv[1], "w") as handle:
                    handle.write(str(os.getpid()))
                time.sleep(30)
                os._exit(0)

            while not os.path.exists(sys.argv[1]):
                time.sleep(0.01)
            print("parent complete", flush=True)
            os._exit(0)
            """)
        defer {
            try? FileManager.default.removeItem(at: cliURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: childPIDFile)
        }

        let result = try TTYCommandRunner().run(
            binary: cliURL.path,
            send: "",
            options: .init(timeout: 2, extraArgs: [childPIDFile.path]))

        #expect(result.completion == .processExited(status: 0))
        #expect(result.text.contains("parent complete"))

        let childPIDText = try String(contentsOf: childPIDFile, encoding: .utf8)
        let childPID = try #require(pid_t(childPIDText.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { _ = kill(childPID, SIGKILL) }
        #expect(kill(childPID, 0) == -1)
    }

    @Test
    func `tty runner preserves completed no-output failure status`() throws {
        let cliURL = try self.makeCLI(
            """
            #!/bin/sh
            exit 23
            """)
        defer { try? FileManager.default.removeItem(at: cliURL.deletingLastPathComponent()) }

        let result = try TTYCommandRunner().run(
            binary: cliURL.path,
            send: "",
            options: .init(timeout: 2, returnOnEmptyProcessExit: true))

        #expect(result.text.isEmpty)
        #expect(result.completion == .processExited(status: 23))
    }

    @Test
    func `tty runner cancellation terminates the process`() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-kiro-cancel-\(UUID().uuidString).pid")
        let cliURL = try self.makeCLI(
            """
            #!/bin/sh
            printf '%s\\n' "$$" > "$1"
            trap '' TERM
            while true; do sleep 1; done
            """)
        defer {
            try? FileManager.default.removeItem(at: cliURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: pidFile)
        }

        let task = Task {
            try TTYCommandRunner().run(
                binary: cliURL.path,
                send: "",
                options: .init(timeout: 20, extraArgs: [pidFile.path]))
        }
        defer { task.cancel() }

        var capturedProcessID: pid_t?
        for _ in 0..<100 {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8) {
                capturedProcessID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let processID = try #require(capturedProcessID)
        defer { _ = kill(processID, SIGKILL) }

        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(kill(processID, 0) == -1)
    }
}

extension KiroStatusProbeTests {
    // MARK: - Happy Path Parsing

    @Test
    func `parses basic usage output`() throws {
        let output = """
        | KIRO FREE                                          |
        ████████████████████████████████████████████████████ 25%
        (12.50 of 50 covered in plan), resets on 01/15
        """

        let probe = KiroStatusProbe()
        let snapshot = try probe.parse(output: output)

        #expect(snapshot.planName == "KIRO FREE")
        #expect(snapshot.displayPlanName == "Kiro Free")
        #expect(snapshot.creditsPercent == 25)
        #expect(snapshot.creditsUsed == 12.50)
        #expect(snapshot.creditsTotal == 50)
        #expect(snapshot.bonusCreditsUsed == nil)
        #expect(snapshot.bonusCreditsTotal == nil)
        #expect(snapshot.bonusExpiryDays == nil)
        #expect(snapshot.resetsAt != nil)
    }

    private func makeCLI(_ script: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-kiro-cli-\(UUID().uuidString)", isDirectory: true)
        let cliURL = root.appendingPathComponent("kiro-cli")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try script.write(to: cliURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliURL.path)
        return cliURL
    }

    @Test
    func `parses output with bonus credits`() throws {
        let output = """
        | KIRO PRO                                           |
        ████████████████████████████████████████████████████ 80%
        (40.00 of 50 covered in plan), resets on 02/01
        Bonus credits: 5.00/10 credits used, expires in 7 days
        """

        let probe = KiroStatusProbe()
        let snapshot = try probe.parse(output: output)

        #expect(snapshot.planName == "KIRO PRO")
        #expect(snapshot.displayPlanName == "Kiro Pro")
        #expect(snapshot.creditsPercent == 80)
        #expect(snapshot.creditsUsed == 40.00)
        #expect(snapshot.creditsTotal == 50)
        #expect(snapshot.bonusCreditsUsed == 5.00)
        #expect(snapshot.bonusCreditsTotal == 10)
        #expect(snapshot.bonusExpiryDays == 7)
    }

    @Test
    func `parses output without percent fallbacks to credits ratio`() throws {
        let output = """
        | KIRO FREE                                          |
        (12.50 of 50 covered in plan), resets on 01/15
        """

        let probe = KiroStatusProbe()
        let snapshot = try probe.parse(output: output)

        #expect(snapshot.creditsPercent == 25)
    }

    @Test
    func `parses bonus credits without expiry`() throws {
        let output = """
        | KIRO FREE                                          |
        ████████████████████████████████████████████████████ 60%
        (30.00 of 50 covered in plan), resets on 04/01
        Bonus credits: 2.00/5 credits used
        """

        let probe = KiroStatusProbe()
        let snapshot = try probe.parse(output: output)

        #expect(snapshot.bonusCreditsUsed == 2.0)
        #expect(snapshot.bonusCreditsTotal == 5.0)
        #expect(snapshot.bonusExpiryDays == nil)
    }

    @Test
    func `parses output with ANSI codes`() throws {
        let output = """
        \u{001B}[32m| KIRO FREE                                          |\u{001B}[0m
        \u{001B}[38;5;11m████████████████████████████████████████████████████\u{001B}[0m 50%
        (25.00 of 50 covered in plan), resets on 03/15
        """

        let probe = KiroStatusProbe()
        let snapshot = try probe.parse(output: output)

        #expect(snapshot.planName == "KIRO FREE")
        #expect(snapshot.creditsPercent == 50)
        #expect(snapshot.creditsUsed == 25.00)
        #expect(snapshot.creditsTotal == 50)
    }

    @Test
    func `parses output with single day`() throws {
        let output = """
        | KIRO FREE                                          |
        ████████████████████████████████████████████████████ 10%
        (5.00 of 50 covered in plan)
        Bonus credits: 2.00/5 credits used, expires in 1 day
        """

        let probe = KiroStatusProbe()
        let snapshot = try probe.parse(output: output)

        #expect(snapshot.bonusExpiryDays == 1)
    }

    @Test
    func `rejects output missing usage markers`() throws {
        let output = """
        | KIRO FREE                                          |
        """

        let probe = KiroStatusProbe()
        #expect(throws: KiroStatusProbeError.self) {
            try probe.parse(output: output)
        }
    }

    // MARK: - New Format (kiro-cli 1.24+, Q Developer)

    @Test
    func `parses Q developer managed plan`() throws {
        let output = """
        Plan: Q Developer Pro
        Your plan is managed by admin

        Tip: to see context window usage, run /context
        """

        let probe = KiroStatusProbe()
        let snapshot = try probe.parse(output: output)

        #expect(snapshot.planName == "Q Developer Pro")
        #expect(snapshot.creditsPercent == 0)
        #expect(snapshot.creditsUsed == 0)
        #expect(snapshot.creditsTotal == 0)
        #expect(snapshot.bonusCreditsUsed == nil)
        #expect(snapshot.resetsAt == nil)
    }

    @Test
    func `parses Q developer free plan`() throws {
        let output = """
        Plan: Q Developer Free
        Your plan is managed by admin
        """

        let probe = KiroStatusProbe()
        let snapshot = try probe.parse(output: output)

        #expect(snapshot.planName == "Q Developer Free")
        #expect(snapshot.creditsPercent == 0)
    }

    @Test
    func `parses new format with ANSI codes`() throws {
        let output = """
        \u{001B}[38;5;141mPlan: Q Developer Pro\u{001B}[0m
        Your plan is managed by admin
        """

        let probe = KiroStatusProbe()
        let snapshot = try probe.parse(output: output)

        #expect(snapshot.planName == "Q Developer Pro")
    }

    @Test
    func `rejects header only new format without managed marker`() {
        let output = """
        Plan: Q Developer Pro
        Tip: to see context window usage, run /context
        """

        let probe = KiroStatusProbe()
        #expect(throws: KiroStatusProbeError.self) {
            try probe.parse(output: output)
        }
    }

    @Test
    func `preserves parsed usage for managed plan with metrics`() throws {
        let output = """
        Plan: Q Developer Enterprise
        Your plan is managed by admin
        ████████████████████████████████████████████████████ 40%
        (20.00 of 50 covered in plan), resets on 03/15
        """

        let probe = KiroStatusProbe()
        let snapshot = try probe.parse(output: output)

        #expect(snapshot.planName == "Q Developer Enterprise")
        #expect(snapshot.creditsPercent == 40)
        #expect(snapshot.creditsUsed == 20)
        #expect(snapshot.creditsTotal == 50)
        #expect(snapshot.resetsAt != nil)
    }

    @Test
    func `parses kiro cli two usage format`() throws {
        let output = """
        \u{001B}[1mEstimated Usage\u{001B}[0m | resets on 2026-06-01 | \u{001B}[mKIRO FREE\u{001B}[0m

        🎁 Bonus credits: 45.53/2000 credits used, expires in 19 days

        \u{001B}[1mCredits\u{001B}[0m (0.17 of 50 covered in plan)
        ████████████████████████████████████████████████████████████████████████████████ 0%

        Overages: \u{001B}[1mDisabled\u{001B}[0m

        To manage your plan or configure overages navigate to https://app.kiro.dev/account/usage
        """

        let probe = KiroStatusProbe()
        let snapshot = try probe.parse(
            output: output,
            accountEmail: "person@example.com",
            authMethod: "Google")

        #expect(snapshot.planName == "KIRO FREE")
        #expect(snapshot.displayPlanName == "Kiro Free")
        #expect(snapshot.accountEmail == "person@example.com")
        #expect(snapshot.authMethod == "Google")
        #expect(snapshot.creditsUsed == 0.17)
        #expect(snapshot.creditsTotal == 50)
        #expect(snapshot.creditsRemaining == 49.83)
        #expect(snapshot.bonusCreditsUsed == 45.53)
        #expect(snapshot.bonusCreditsTotal == 2000)
        #expect(snapshot.bonusCreditsRemaining == 1954.47)
        #expect(snapshot.bonusExpiryDays == 19)
        #expect(snapshot.overagesStatus == "Disabled")
        #expect(snapshot.manageURL == "https://app.kiro.dev/account/usage")
        #expect(snapshot.resetsAt != nil)
    }

    @Test
    func `parses kiro overage credits and estimated cost`() throws {
        let output = """
        Estimated Usage | resets on 2026-06-01 | KIRO PRO
        Credits (1000.00 of 1000 covered in plan)
        ████████████████████████████████████████████████████████████████████████████████ 100%

        Overages: Enabled  billed at $0.04 per request
        Credits used: 40.29
        Est. cost: $1.61 USD

        To manage your plan or configure overages navigate to https://app.kiro.dev/account/usage
        """

        let probe = KiroStatusProbe()
        let snapshot = try probe.parse(output: output)

        #expect(snapshot.planName == "KIRO PRO")
        #expect(snapshot.creditsUsed == 1000)
        #expect(snapshot.creditsTotal == 1000)
        #expect(snapshot.overagesStatus == "Enabled  billed at $0.04 per request")
        #expect(snapshot.overageCreditsUsed == 40.29)
        #expect(snapshot.estimatedOverageCostUSD == 1.61)
    }

    @Test
    func `parses context usage`() throws {
        let output = """
        Context window: 1.3% used (estimated)
        ██████████████████████████████████████████████████████████████████████████████ 1.3%

        █ Context files 0.5% (estimated)
        █ Tools 0.8% (estimated)
        █ Kiro responses 0.0% (estimated)
        █ Your prompts 0.0% (estimated)
        """

        let probe = KiroStatusProbe()
        let context = try #require(probe.parseContextUsage(output: output))

        #expect(context.totalPercentUsed == 1.3)
        #expect(context.contextFilesPercent == 0.5)
        #expect(context.toolsPercent == 0.8)
        #expect(context.kiroResponsesPercent == 0)
        #expect(context.promptsPercent == 0)
    }

    // MARK: - Snapshot Conversion

    @Test
    func `converts snapshot to usage snapshot`() throws {
        let now = Date()
        let resetDate = try #require(Calendar.current.date(byAdding: .day, value: 7, to: now))

        let snapshot = KiroUsageSnapshot(
            planName: "KIRO PRO",
            creditsUsed: 25.0,
            creditsTotal: 100.0,
            creditsPercent: 25.0,
            bonusCreditsUsed: 5.0,
            bonusCreditsTotal: 20.0,
            bonusExpiryDays: 14,
            resetsAt: resetDate,
            updatedAt: now)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 25.0)
        #expect(usage.primary?.resetsAt == resetDate)
        #expect(usage.secondary?.usedPercent == 25.0) // 5/20 * 100
        #expect(usage.loginMethod(for: .kiro) == nil)
        #expect(usage.accountOrganization(for: .kiro) == nil)
        #expect(usage.kiroUsage?.displayPlanName == "Kiro Pro")
        #expect(usage.kiroUsage?.creditsRemaining == 75)
    }

    @Test
    func `converts snapshot without bonus credits`() {
        let snapshot = KiroUsageSnapshot(
            planName: "KIRO FREE",
            creditsUsed: 10.0,
            creditsTotal: 50.0,
            creditsPercent: 20.0,
            bonusCreditsUsed: nil,
            bonusCreditsTotal: nil,
            bonusExpiryDays: nil,
            resetsAt: nil,
            updatedAt: Date())

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 20.0)
        #expect(usage.secondary == nil)
    }

    // MARK: - Error Cases

    @Test
    func `empty output throws parse error`() {
        let probe = KiroStatusProbe()

        #expect(throws: KiroStatusProbeError.self) {
            try probe.parse(output: "")
        }
    }

    @Test
    func `warning output throws parse error`() {
        let output = """
        \u{001B}[38;5;11m⚠️  Warning: Could not retrieve usage information from backend
        \u{001B}[38;5;8mError: dispatch failure (io error): an i/o error occurred
        """

        let probe = KiroStatusProbe()

        #expect(throws: KiroStatusProbeError.self) {
            try probe.parse(output: output)
        }
    }

    @Test
    func `unrecognized format throws parse error`() {
        // Simulates a CLI format change where none of the expected patterns match
        let output = """
        Welcome to Kiro!
        Your account is active.
        Usage: unknown format
        """

        let probe = KiroStatusProbe()

        #expect {
            try probe.parse(output: output)
        } throws: { error in
            guard case let KiroStatusProbeError.parseError(msg) = error else { return false }
            return msg.contains("No recognizable usage patterns")
        }
    }

    @Test
    func `login prompt throws not logged in`() {
        let output = """
        Failed to initialize auth portal.
        Please try again with: kiro-cli login --use-device-flow
        error: OAuth error: All callback ports are in use.
        """

        let probe = KiroStatusProbe()

        #expect {
            try probe.parse(output: output)
        } throws: { error in
            guard case KiroStatusProbeError.notLoggedIn = error else { return false }
            return true
        }
    }

    // MARK: - WhoAmI Validation

    @Test
    func `whoami not logged in throws`() {
        let probe = KiroStatusProbe()

        #expect {
            try probe.validateWhoAmIOutput(stdout: "Not logged in", stderr: "", terminationStatus: 1)
        } throws: { error in
            guard case KiroStatusProbeError.notLoggedIn = error else { return false }
            return true
        }
    }

    @Test
    func `whoami login required throws`() {
        let probe = KiroStatusProbe()

        #expect {
            try probe.validateWhoAmIOutput(stdout: "login required", stderr: "", terminationStatus: 1)
        } throws: { error in
            guard case KiroStatusProbeError.notLoggedIn = error else { return false }
            return true
        }
    }

    @Test
    func `whoami empty output with zero status throws`() {
        let probe = KiroStatusProbe()

        #expect {
            try probe.validateWhoAmIOutput(stdout: "", stderr: "", terminationStatus: 0)
        } throws: { error in
            guard case KiroStatusProbeError.cliFailed = error else { return false }
            return true
        }
    }

    @Test
    func `whoami non zero status with message throws`() {
        let probe = KiroStatusProbe()

        #expect {
            try probe.validateWhoAmIOutput(stdout: "", stderr: "Connection error", terminationStatus: 1)
        } throws: { error in
            guard case KiroStatusProbeError.cliFailed = error else { return false }
            return true
        }
    }

    @Test
    func `whoami success does not throw`() throws {
        let probe = KiroStatusProbe()

        let account = try probe.validateWhoAmIOutput(
            stdout: """
            Logged in with Google
            Email: user@example.com
            """,
            stderr: "",
            terminationStatus: 0)

        #expect(account.authMethod == "Google")
        #expect(account.email == "user@example.com")
    }

    @Test
    func `whoami legacy bare email parses account`() throws {
        let probe = KiroStatusProbe()

        let account = try probe.validateWhoAmIOutput(
            stdout: "user@example.com",
            stderr: "",
            terminationStatus: 0)

        #expect(account.authMethod == nil)
        #expect(account.email == "user@example.com")
    }
}

extension KiroStatusProbeTests {
    @Test
    func `fetch cancellation while joining account after usage failure is preserved`() async throws {
        let accountStarted = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-kiro-failed-usage-account-\(UUID().uuidString).started")
        let cliURL = try self.makeCLI(
            """
            #!/bin/sh
            if [ "$1" = "whoami" ]; then
              : > '\(accountStarted.path)'
              trap '' TERM
              while true; do sleep 1; done
            fi

            if [ "$1" = "chat" ] && [ "$3" = "/usage" ]; then
              exit 1
            fi

            exit 1
            """)
        defer {
            try? FileManager.default.removeItem(at: cliURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: accountStarted)
        }

        let probe = KiroStatusProbe(cliBinaryResolver: { cliURL.path }, accountProbeTimeout: 2.0)
        let task = Task { try await probe.fetch() }
        defer { task.cancel() }

        try await waitForFile(accountStarted)
        try await Task.sleep(for: .milliseconds(300))

        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}
