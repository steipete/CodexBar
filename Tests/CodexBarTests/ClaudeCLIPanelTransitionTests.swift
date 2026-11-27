import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeCLIPanelTransitionTests {
    @Test
    func `reused session dismisses usage before identity and refreshes usage in a new process`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-panel-transition-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("fake-claude")
        let log = directory.appendingPathComponent("commands.log")
        let script = #"""
        #!/bin/bash
        /bin/stty raw -echo -icrnl
        printf 'launch\n' >> "$HOME/commands.log"
        panel=closed
        command=''
        while IFS= read -r -n 1 key; do
          case "$key" in
            $'\e')
              printf 'dismiss:%s\n' "$panel" >> "$HOME/commands.log"
              /bin/sleep 0.05
              panel=closed
              command=''
              printf 'prompt\r\n'
              ;;
            # read -n 1 reports a newline as an empty key.
            $'\r'|'')
              if [[ "$panel" == closed ]]; then
                printf '%s\n' "$command" >> "$HOME/commands.log"
                case "$command" in
                  /usage)
                    printf 'Current session\r\n9%% used\r\nDONE\r\n'
                    panel=usage
                    ;;
                  /status)
                    printf 'Email: fixture@example.com\r\nLogin method: Claude Max Account\r\nDONE\r\n'
                    panel=status
                    ;;
                esac
              fi
              command=''
              ;;
            *) command+="$key" ;;
          esac
        done
        """#
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let session = ClaudeCLISession(workingDirectory: directory)
        let environment = [
            "HOME": directory.path,
            "CLAUDE_CONFIG_DIR": directory.path,
            "CLAUDE_SECURESTORAGE_CONFIG_DIR": directory.path,
            "CODEXBAR_DISABLE_CLAUDE_WATCHDOG": "1",
        ]
        func capture(_ command: String) async throws -> String {
            try await session.capture(
                subcommand: command,
                binary: binary.path,
                accountScope: "synthetic-account",
                timeout: 3,
                environment: environment,
                idleTimeout: 0.5,
                stopOnSubstrings: ["DONE"],
                settleAfterStop: 0)
        }
        do {
            let usage = try await capture("/usage")
            let status = try await capture("/status")
            let snapshot = try ClaudeStatusProbe.parse(text: usage, statusText: status)
            #expect(snapshot.sessionPercentLeft == 91)
            #expect(snapshot.accountEmail == "fixture@example.com")
            #expect(snapshot.loginMethod == "Max")
            let refreshed = try await capture("/usage")
            #expect(try ClaudeStatusProbe.parse(text: refreshed).sessionPercentLeft == 91)
            await session.reset()
        } catch {
            print("Synthetic CLI commands:\n" + ((try? String(contentsOf: log, encoding: .utf8)) ?? "<none>"))
            await session.reset()
            throw error
        }
        #expect(try String(contentsOf: log, encoding: .utf8) == """
        launch
        /usage
        dismiss:usage
        /status
        launch
        /usage

        """)
    }

    @Test
    func `usage replays each fresh process from launch and ignores a status line quota`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-usage-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("fake-claude")
        // Like Claude's differential renderer, /usage reuses the "r" at column 6 that the startup screen drew and a
        // refresh rewrites only the changed digit. Launch 4 stalls while a custom status line shows "53% used".
        let script = #"""
        #!/bin/bash
        /bin/stty raw -echo -icrnl
        launch=$(( $(/bin/cat "$HOME/launches" 2>/dev/null || echo 0) + 1 ))
        printf '%s' "$launch" > "$HOME/launches"
        printf '\e[H\e[2J\e[3;1H  Start typing'
        command=''
        while IFS= read -r -n 1 key; do
          case "$key" in
            $'\r'|'')
              if [[ "$command" == /usage ]]; then
                printf '\e[3;3HCur\e[3;7Hent week (all models)'
                case "$launch" in
                  1)
                    printf '\e[4;3H██ 52%% used\e[5;3HResets Nov 24 at 4:59am (America/Los_Angeles)'
                    printf '\e[6;3HCurrent week (Fable)\e[7;3H█ 8%% used\e[9;3HRefreshing… esc to cancel'
                    /bin/sleep 0.4
                    printf '\e[4;7H3\e[9;1H\e[K'
                    ;;
                  4) printf '\e[4;3HLoading usage data…\e[20;3H53%% used' ;;
                  *) printf '\e[4;3H███ 60%% used\e[5;3HResets Nov 24 at 4:59am (America/Los_Angeles)' ;;
                esac
              fi
              command=''
              ;;
            *) command+="$key" ;;
          esac
        done
        """#
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let session = ClaudeCLISession(workingDirectory: directory)
        let environment = [
            "HOME": directory.path,
            "CLAUDE_CONFIG_DIR": directory.path,
            "CLAUDE_SECURESTORAGE_CONFIG_DIR": directory.path,
            "CODEXBAR_DISABLE_CLAUDE_WATCHDOG": "1",
        ]
        func usage(account: String = "synthetic-account", timeout: TimeInterval = 8) async throws -> String {
            try await session.capture(
                subcommand: "/usage",
                binary: binary.path,
                accountScope: account,
                timeout: timeout,
                environment: environment,
                idleTimeout: nil,
                stopWhenNormalized: { ClaudeStatusProbe.usageCaptureIsComplete($0) },
                settleAfterStop: 0.1)
        }
        func weeklyPercentLeft(_ text: String) throws -> Int? {
            try ClaudeStatusProbe.parse(text: text).weeklyPercentLeft
        }
        do {
            let first = try await usage()
            let redrawn = try ClaudeStatusProbe.parse(text: first)
            #expect(redrawn.weeklyPercentLeft == 47)
            #expect(redrawn.secondaryResetDescription == "Resets Nov 24 at 4:59am (America/Los_Angeles)")
            #expect(redrawn.extraRateWindows.first { $0.id == "claude-weekly-scoped-fable" }?.window
                .usedPercent == 8)

            let second = try await usage()
            #expect(try weeklyPercentLeft(second) == 40)
            let started = Date()
            let unchanged = try await usage()
            #expect(Date().timeIntervalSince(started) < 8)
            #expect(try weeklyPercentLeft(unchanged) == 40)

            let stalled = try await usage(timeout: 1.5)
            #expect(throws: ClaudeStatusProbeError.self) { try ClaudeStatusProbe.parse(text: stalled) }

            let replaced = try await usage(account: "other-synthetic-account")
            #expect(!replaced.contains("Loading usage"))
            #expect(try weeklyPercentLeft(replaced) == 40)
            await session.reset()
        } catch {
            await session.reset()
            throw error
        }
        let launches = try String(contentsOf: directory.appendingPathComponent("launches"), encoding: .utf8)
        #expect(launches == "5")
    }
}
