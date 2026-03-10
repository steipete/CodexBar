import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct TTYCommandRunnerEnvTests {
    @Test
    func shutdownFenceDrainsTrackedTTYProcesses() {
        TTYCommandRunner._test_resetTrackedProcesses()
        defer { TTYCommandRunner._test_resetTrackedProcesses() }

        #expect(TTYCommandRunner._test_registerTrackedProcess(pid: 1001, binary: "codex"))
        #expect(TTYCommandRunner._test_trackedProcessCount() == 1)

        let drained = TTYCommandRunner._test_drainTrackedProcessesForShutdown()
        #expect(drained.count == 1)
        #expect(drained[0].pid == 1001)
        #expect(TTYCommandRunner._test_trackedProcessCount() == 0)
    }

    @Test
    func trackedProcessHelpersIgnoreInvalidPID() {
        TTYCommandRunner._test_resetTrackedProcesses()
        defer { TTYCommandRunner._test_resetTrackedProcesses() }

        TTYCommandRunner._test_trackProcess(pid: 0, binary: "codex", processGroup: nil)
        #expect(TTYCommandRunner._test_trackedProcessCount() == 0)
    }

    @Test
    func shutdownFenceRejectsNewRegistrations() {
        TTYCommandRunner._test_resetTrackedProcesses()
        defer { TTYCommandRunner._test_resetTrackedProcesses() }

        #expect(TTYCommandRunner._test_registerTrackedProcess(pid: 2001, binary: "codex"))
        let drained = TTYCommandRunner._test_drainTrackedProcessesForShutdown()
        #expect(drained.count == 1)

        #expect(TTYCommandRunner._test_registerTrackedProcess(pid: 2002, binary: "codex") == false)
        #expect(TTYCommandRunner._test_trackedProcessCount() == 0)
    }

    @Test
    func shutdownResolverSkipsHostProcessGroupFallback() {
        let hostGroup: pid_t = 4242
        let targets: [(pid: pid_t, binary: String, processGroup: pid_t?)] = [
            (pid: 100, binary: "codex", processGroup: nil),
            (pid: 101, binary: "codex", processGroup: hostGroup),
            (pid: 102, binary: "codex", processGroup: 7777),
        ]

        let resolved = TTYCommandRunner._test_resolveShutdownTargets(
            targets,
            hostProcessGroup: hostGroup,
            groupResolver: { pid in
                pid == 100 ? hostGroup : -1
            })

        #expect(resolved.count == 3)
        #expect(resolved[0].processGroup == nil)
        #expect(resolved[1].processGroup == nil)
        #expect(resolved[2].processGroup == 7777)
    }

    @Test
    func preservesEnvironmentAndSetsTerm() {
        let baseEnv: [String: String] = [
            "PATH": "/custom/bin",
            "HOME": "/Users/tester",
            "LANG": "en_US.UTF-8",
        ]

        let merged = TTYCommandRunner.enrichedEnvironment(
            baseEnv: baseEnv,
            loginPATH: nil,
            home: "/Users/tester")

        #expect(merged["HOME"] == "/Users/tester")
        #expect(merged["LANG"] == "en_US.UTF-8")
        #expect(merged["TERM"] == "xterm-256color")

        #expect(merged["PATH"] == "/custom/bin")
    }

    @Test
    func backfillsHomeWhenMissing() {
        let merged = TTYCommandRunner.enrichedEnvironment(
            baseEnv: ["PATH": "/custom/bin"],
            loginPATH: nil,
            home: "/Users/fallback")
        #expect(merged["HOME"] == "/Users/fallback")
        #expect(merged["TERM"] == "xterm-256color")
    }

    @Test
    func preservesExistingTermAndCustomVars() {
        let merged = TTYCommandRunner.enrichedEnvironment(
            baseEnv: [
                "PATH": "/custom/bin",
                "TERM": "vt100",
                "BUN_INSTALL": "/Users/tester/.bun",
                "SHELL": "/bin/zsh",
            ],
            loginPATH: nil,
            home: "/Users/tester")

        #expect(merged["TERM"] == "vt100")
        #expect(merged["BUN_INSTALL"] == "/Users/tester/.bun")
        #expect(merged["SHELL"] == "/bin/zsh")
        #expect((merged["PATH"] ?? "").contains("/custom/bin"))
    }

    @Test
    func setsWorkingDirectoryWhenProvided() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("codexbar-tty-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let runner = TTYCommandRunner()
        let result = try runner.run(binary: "/bin/pwd", send: "", options: .init(timeout: 3, workingDirectory: dir))
        let clean = result.text.replacingOccurrences(of: "\r", with: "")
        #expect(clean.contains(dir.path))
    }

    @Test
    func autoRespondsToTrustPrompt() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("codexbar-tty-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let scriptURL = dir.appendingPathComponent("trust.sh")
        let script = """
        #!/bin/sh
        echo \"Do you trust the files in this folder?\"
        echo \"\"
        echo \"/Users/example/project\"
        IFS= read -r ans
        if [ \"$ans\" = \"y\" ] || [ \"$ans\" = \"Y\" ]; then
          echo \"accepted\"
        else
          echo \"rejected:$ans\"
        fi
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let runner = TTYCommandRunner()
        let result = try runner.run(
            binary: scriptURL.path,
            send: "",
            options: .init(
                timeout: 6,
                // Use LF for portability: some PTY/termios setups do not translate CR → NL for shell reads.
                sendOnSubstrings: ["trust the files in this folder?": "y\n"],
                stopOnSubstrings: ["accepted", "rejected"],
                settleAfterStop: 0.1))

        #expect(result.text.contains("accepted"))
    }

    @Test
    func stopsWhenOutputIsIdle() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("codexbar-tty-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let scriptURL = dir.appendingPathComponent("idle.sh")
        let script = """
        #!/bin/sh
        echo "hello"
        sleep 30
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let runner = TTYCommandRunner()
        let timeout: TimeInterval = 6
        var fastestElapsed = TimeInterval.greatestFiniteMagnitude
        // CI can occasionally pause a test process long enough to miss an idle window.
        // Retry once and assert that at least one run exits well before timeout.
        for _ in 0..<2 {
            let startedAt = Date()
            let result = try runner.run(
                binary: scriptURL.path,
                send: "",
                options: .init(timeout: timeout, idleTimeout: 0.2))
            let elapsed = Date().timeIntervalSince(startedAt)

            #expect(result.text.contains("hello"))
            fastestElapsed = min(fastestElapsed, elapsed)
        }
        #expect(fastestElapsed < (timeout - 1.0))
    }

    @Test
    func rollingBufferDetectsNeedleAcrossBoundary() {
        var scanner = TTYCommandRunner.RollingBuffer(maxNeedle: 6)
        let needle = Data("hello".utf8)
        let first = scanner.append(Data("he".utf8))
        #expect(first.range(of: needle) == nil)
        let second = scanner.append(Data("llo!".utf8))
        #expect(second.range(of: needle) != nil)
    }

    @Test
    func lowercasedASCIIOnlyTouchesAscii() {
        let data = Data("UpDaTe".utf8)
        let lowered = TTYCommandRunner.lowercasedASCII(data)
        #expect(String(data: lowered, encoding: .utf8) == "update")
    }
}
