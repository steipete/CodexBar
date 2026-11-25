import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeCLIPanelTransitionTests {
    @Test
    func `reused session dismisses panels before capturing identity and refreshing usage`() async throws {
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
        dismiss:status
        /usage

        """)
    }

    @Test
    func `usage capture redraws over the startup screen without reusing stale quotas`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-usage-baseline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("fake-claude")
        // Like Claude's differential renderer, the first /usage reuses the startup "r" at column 6 and its refresh
        // rewrites only the changed digit. Escape leaves the panel visible; the second /usage again rewrites only a
        // digit, and later /usage commands never finish while a custom status line draws its own "% used" row.
        let script = #"""
        #!/bin/bash
        /bin/stty raw -echo -icrnl
        printf '\e[H\e[2J\e[3;1H  Start typing'
        command=''
        count=0
        while IFS= read -r -n 1 key; do
          case "$key" in
            $'\e') command='' ;;
            $'\r'|'')
              if [[ "$command" == /usage ]]; then
                count=$((count + 1))
                if [[ $count == 1 ]]; then
                  printf '\e[3;3HCur\e[3;7Hent week (all models)\e[4;3H██ 52%% used'
                  printf '\e[5;3HResets Nov 24 at 4:59am (America/Los_Angeles)'
                  printf '\e[6;3HCurrent week (Fable)\e[7;3H█ 8%% used\e[9;3HRefreshing… esc to cancel'
                  /bin/sleep 0.4
                  printf '\e[4;7H3\e[9;1H\e[K'
                elif [[ $count == 2 ]]; then
                  printf '\e[4;7H5'
                else
                  printf '\e[11;3HLoading usage data…\e[20;3H53%% used'
                fi
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
        func usage(account: String, timeout: TimeInterval) async throws -> String {
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
        func assertAllModelsWeekly(_ text: String, percentLeft: Int = 47) throws {
            let snapshot = try ClaudeStatusProbe.parse(text: text)
            #expect(snapshot.weeklyPercentLeft == percentLeft)
            #expect(snapshot.secondaryResetDescription == "Resets Nov 24 at 4:59am (America/Los_Angeles)")
            #expect(snapshot.extraRateWindows.first { $0.id == "claude-weekly-scoped-fable" }?.window
                .usedPercent == 8)
        }
        do {
            try await assertAllModelsWeekly(usage(account: "synthetic-account", timeout: 5))
            try await assertAllModelsWeekly(usage(account: "synthetic-account", timeout: 3), percentLeft: 45)

            let stale = try await usage(account: "synthetic-account", timeout: 1.5)
            let staleScreen = ClaudeCLIScreen.render(stale)
            #expect(!staleScreen.contains("Current"))
            #expect(!ClaudeStatusProbe.usageCaptureIsComplete(
                String(staleScreen.lowercased().filter { !$0.isWhitespace })))
            #expect(throws: ClaudeStatusProbeError.self) { try ClaudeStatusProbe.parse(text: stale) }

            let replaced = try await usage(account: "other-synthetic-account", timeout: 5)
            #expect(!replaced.contains("Loading usage"))
            try assertAllModelsWeekly(replaced)
            await session.reset()
        } catch {
            await session.reset()
            throw error
        }
    }
}
