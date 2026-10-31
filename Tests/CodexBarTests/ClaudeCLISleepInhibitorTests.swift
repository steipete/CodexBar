#if canImport(Darwin)
import Darwin
import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeCLISleepInhibitorTests {
    @Test(arguments: [false, true])
    func `passive captures release only caffeinate in their owned process groups`(useWatchdog: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-sleep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let companion = directory.appendingPathComponent("caffeinate")
        try FileManager.default.createSymbolicLink(atPath: companion.path, withDestinationPath: "/bin/sleep")
        let scriptName = useWatchdog ? "claude" : "synthetic-claude"
        let script = directory.appendingPathComponent(scriptName)
        try """
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *"/status"*)
              /usr/bin/caffeinate -i -t 30 &
              inhibitor=$!
              '\(companion.path)' 30 &
              companion=$!
              /bin/sleep 0.1
              printf 'Probe ready: %s %s %s %s\\n' "$$" "$PPID" "$inhibitor" "$companion"
              ;;
          esac
        done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        var environment: [String: String] = ["PATH": "/usr/bin:/bin", "HOME": directory.path]
        if useWatchdog {
            let watchdogURL = try await ClaudeWatchdogTests.buildWatchdogExecutable(in: directory)
            environment["CODEXBAR_HELPER_CODEXBARCLAUDEWATCHDOG"] = watchdogURL.path
        }

        // A real executable in a separate synthetic group proves the group boundary, without a live account.
        let outside = Process()
        outside.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        outside.arguments = ["-i", "-t", 30.description]
        try outside.run()
        defer {
            if outside.isRunning { outside.terminate() }
        }
        let session = ClaudeCLISession(workingDirectory: directory)
        do {
            var previousGroup: pid_t?
            for _ in 0..<2 {
                let output = try await session.capture(
                    subcommand: "/status",
                    binary: script.path,
                    timeout: 8,
                    environment: environment,
                    stopOnSubstrings: ["Probe ready:"])
                let line = try #require(output.components(separatedBy: "\n").first { $0.contains("Probe ready: ") })
                let pids = line.split(separator: " ")
                    .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                #expect(pids.count == 4)
                let claudePID = try #require(pids.first)
                let parentPID = try #require(pids.dropFirst().first)
                let inhibitor = try #require(pids.dropFirst(2).first)
                let companionPID = try #require(pids.last)
                let claudeGroup = getpgid(claudePID)
                if let previousGroup { #expect(claudeGroup == previousGroup) }
                previousGroup = claudeGroup
                #expect(claudeGroup == claudePID)
                if useWatchdog {
                    #expect(getpgid(parentPID) == parentPID)
                    #expect(claudeGroup != getpgid(parentPID))
                }
                #expect(getpgid(companionPID) == claudeGroup)
                #expect(getpgid(outside.processIdentifier) != claudeGroup)
                let deadline = Date().addingTimeInterval(1)
                while DarwinProcessEnumerator.executablePath(pid: inhibitor) == "/usr/bin/caffeinate",
                      Date() < deadline
                {
                    try await Task.sleep(for: .milliseconds(20))
                }
                #expect(DarwinProcessEnumerator.executablePath(pid: inhibitor) != "/usr/bin/caffeinate")
                #expect(kill(companionPID, 0) == 0)
                #expect(outside.isRunning)
            }
            await session.reset()
        } catch {
            await session.reset()
            throw error
        }
    }

    @Test
    func `session reset reaps marked watchdog child group and rejects unmarked isolated groups`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-reap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let watchdogURL = try await ClaudeWatchdogTests.buildWatchdogExecutable(in: directory)
        let script = directory.appendingPathComponent("claude")
        try """
        #!/bin/sh
        trap '' TERM
        /bin/sleep 30 &
        descendant=$!
        while IFS= read -r line; do
          case "$line" in
            *"/status"*)
              printf 'Probe ready: %s %s\\n' "$$" "$descendant"
              ;;
          esac
        done
        /bin/sleep 30
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        unrelated.arguments = ["-i", "-t", "30"]
        try unrelated.run()
        let unrelatedPID = unrelated.processIdentifier
        _ = setpgid(unrelatedPID, unrelatedPID)
        defer {
            if unrelated.isRunning { unrelated.terminate() }
        }

        let environment: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "HOME": directory.path,
            "CODEXBAR_HELPER_CODEXBARCLAUDEWATCHDOG": watchdogURL.path,
        ]
        let session = ClaudeCLISession(workingDirectory: directory)
        do {
            let output = try await session.capture(
                subcommand: "/status",
                binary: script.path,
                timeout: 8,
                environment: environment,
                stopOnSubstrings: ["Probe ready:"])
            let line = try #require(output.components(separatedBy: "\n").first { $0.contains("Probe ready: ") })
            let pids = line.split(separator: " ")
                .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            #expect(pids.count == 2)
            let claudePID = try #require(pids.first)
            let descendantPID = try #require(pids.last)
            #expect(kill(claudePID, 0) == 0)
            #expect(kill(descendantPID, 0) == 0)
            #expect(unrelated.isRunning)

            await session.reset()

            let deadline = Date().addingTimeInterval(2.0)
            while kill(claudePID, 0) == 0 || kill(descendantPID, 0) == 0, Date() < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(kill(claudePID, 0) != 0)
            #expect(kill(descendantPID, 0) != 0)
            #expect(unrelated.isRunning)
        } catch {
            await session.reset()
            throw error
        }
    }

    @Test(arguments: [false, true])
    func `passive capture releases owned caffeinate after intermediate launcher shell exits`(
        useWatchdog: Bool) async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-orphan-inhibitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let inhibitorFile = directory.appendingPathComponent("inhibitor.pid")
        let scriptName = useWatchdog ? "claude" : "synthetic-claude"
        let script = directory.appendingPathComponent(scriptName)
        try """
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *"/status"*)
              /bin/sh -c '/usr/bin/caffeinate -i -t 30 >/dev/null 2>&1 & printf "%s\\n" "$!" > "\(inhibitorFile.path)"'
              inhibitor=$(/bin/cat "\(inhibitorFile.path)")
              /bin/sleep 0.1
              ppid=$(/bin/ps -o ppid= -p "$inhibitor" | /usr/bin/tr -d ' ')
              printf 'Probe ready: %s %s\\n' "$inhibitor" "$ppid"
              ;;
          esac
        done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        var environment: [String: String] = ["PATH": "/usr/bin:/bin", "HOME": directory.path]
        if useWatchdog {
            let watchdogURL = try await ClaudeWatchdogTests.buildWatchdogExecutable(in: directory)
            environment["CODEXBAR_HELPER_CODEXBARCLAUDEWATCHDOG"] = watchdogURL.path
        }

        let outside = Process()
        outside.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        outside.arguments = ["-i", "-t", "30"]
        try outside.run()
        defer {
            if outside.isRunning { outside.terminate() }
        }

        let session = ClaudeCLISession(workingDirectory: directory)
        do {
            let output = try await session.capture(
                subcommand: "/status",
                binary: script.path,
                timeout: 8,
                environment: environment,
                stopOnSubstrings: ["Probe ready:"])
            let line = try #require(output.components(separatedBy: "\n").first { $0.contains("Probe ready: ") })
            let values = line.split(separator: " ")
                .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            #expect(values.count == 2)
            let inhibitorPID = try #require(values.first)
            let inhibitorPPID = try #require(values.last)
            #expect(inhibitorPPID == 1)

            let deadline = Date().addingTimeInterval(1.0)
            while DarwinProcessEnumerator.executablePath(pid: inhibitorPID) == "/usr/bin/caffeinate",
                  Date() < deadline
            {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(DarwinProcessEnumerator.executablePath(pid: inhibitorPID) != "/usr/bin/caffeinate")
            #expect(outside.isRunning)
            await session.reset()
        } catch {
            await session.reset()
            throw error
        }
    }

    @Test
    func `session reset terminates escaped descendant without signaling external group sentinel`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-escaped-group-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let watchdogURL = try await ClaudeWatchdogTests.buildWatchdogExecutable(in: directory)
        let sentinel = Process()
        sentinel.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sentinel.arguments = ["30"]
        try sentinel.run()
        let sentinelPID = sentinel.processIdentifier
        #expect(setpgid(sentinelPID, sentinelPID) == 0 || getpgid(sentinelPID) == sentinelPID)
        defer {
            if sentinel.isRunning { sentinel.terminate() }
        }

        let escapedFile = directory.appendingPathComponent("escaped.txt")
        let script = directory.appendingPathComponent("claude")
        try """
        #!/bin/sh
        trap '' TERM
        while IFS= read -r line; do
          case "$line" in
            *"/status"*)
              /usr/bin/python3 -c '
        import os, signal, sys, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        os.setpgid(0, int(sys.argv[1]))
        with open(sys.argv[2], "w") as f:
            f.write(f"{os.getpid()} {os.getpgrp()}\\n")
        time.sleep(30)
        ' "\(sentinelPID)" "\(escapedFile.path)" >/dev/null 2>&1 &
              attempts=0
              while [ ! -s "\(escapedFile.path)" ] && [ "$attempts" -lt 250 ]; do
                /bin/sleep 0.02
                attempts=$((attempts + 1))
              done
              [ -s "\(escapedFile.path)" ] || exit 1
              escaped_info=$(/bin/cat "\(escapedFile.path)")
              printf 'Probe ready: %s %s\\n' "$$" "$escaped_info"
              ;;
          esac
        done
        /bin/sleep 30
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let environment: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "HOME": directory.path,
            "CODEXBAR_HELPER_CODEXBARCLAUDEWATCHDOG": watchdogURL.path,
        ]
        let session = ClaudeCLISession(workingDirectory: directory)
        do {
            let output = try await session.capture(
                subcommand: "/status",
                binary: script.path,
                timeout: 8,
                environment: environment,
                stopOnSubstrings: ["Probe ready:"])
            let line = try #require(output.components(separatedBy: "\n").first { $0.contains("Probe ready: ") })
            let values = line.split(separator: " ")
                .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            #expect(values.count == 3)
            let claudePID = try #require(values.first)
            let escapedPID = try #require(values.dropFirst().first)
            let escapedPGID = try #require(values.last)
            #expect(escapedPGID == sentinelPID)
            #expect(getpgid(escapedPID) == sentinelPID)
            #expect(getpgid(sentinelPID) == sentinelPID)
            #expect(kill(claudePID, 0) == 0)
            #expect(kill(escapedPID, 0) == 0)
            #expect(sentinel.isRunning)

            await session.reset()

            let deadline = Date().addingTimeInterval(2.0)
            while kill(claudePID, 0) == 0 || kill(escapedPID, 0) == 0, Date() < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(kill(claudePID, 0) != 0)
            #expect(kill(escapedPID, 0) != 0)
            #expect(sentinel.isRunning)
            #expect(kill(sentinelPID, 0) == 0)
        } catch {
            await session.reset()
            throw error
        }
    }
}
#endif
