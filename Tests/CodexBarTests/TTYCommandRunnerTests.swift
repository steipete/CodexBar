import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct TTYCommandRunnerEnvTests {
    private final class CallbackCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            self.lock.lock()
            self.count += 1
            self.lock.unlock()
        }

        func value() -> Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.count
        }
    }

    @Test
    func `shutdown fence drains tracked TTY processes`() {
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
    func `cached CLI sessions share shutdown tracking`() {
        TTYCommandRunner._test_resetTrackedProcesses()
        defer { TTYCommandRunner._test_resetTrackedProcesses() }

        #expect(TTYCommandRunner.registerActiveProcessForAppShutdown(pid: 3001, binary: "codex"))
        TTYCommandRunner.updateActiveProcessGroupForAppShutdown(pid: 3001, processGroup: 3001)
        #expect(TTYCommandRunner._test_trackedProcessCount() == 1)

        TTYCommandRunner.unregisterActiveProcessForAppShutdown(pid: 3001)
        #expect(TTYCommandRunner._test_trackedProcessCount() == 0)
    }

    @Test
    func `tracked process helpers ignore invalid PID`() {
        TTYCommandRunner._test_resetTrackedProcesses()
        defer { TTYCommandRunner._test_resetTrackedProcesses() }

        TTYCommandRunner._test_trackProcess(pid: 0, binary: "codex", processGroup: nil)
        #expect(TTYCommandRunner._test_trackedProcessCount() == 0)
    }

    @Test
    func `shutdown fence rejects new registrations`() {
        TTYCommandRunner._test_resetTrackedProcesses()
        defer { TTYCommandRunner._test_resetTrackedProcesses() }

        #expect(TTYCommandRunner._test_registerTrackedProcess(pid: 2001, binary: "codex"))
        let drained = TTYCommandRunner._test_drainTrackedProcessesForShutdown()
        #expect(drained.count == 1)

        #expect(TTYCommandRunner._test_registerTrackedProcess(pid: 2002, binary: "codex") == false)
        #expect(TTYCommandRunner._test_trackedProcessCount() == 0)
    }

    @Test
    func `shutdown resolver skips host process group fallback`() {
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
    func `preserves environment and sets term`() {
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
    func `backfills home when missing`() {
        let merged = TTYCommandRunner.enrichedEnvironment(
            baseEnv: ["PATH": "/custom/bin"],
            loginPATH: nil,
            home: "/Users/fallback")
        #expect(merged["HOME"] == "/Users/fallback")
        #expect(merged["TERM"] == "xterm-256color")
    }

    @Test
    func `preserves existing term and custom vars`() {
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
    func `sets working directory when provided`() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("codexbar-tty-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let runner = TTYCommandRunner()
        let result = try runner.run(binary: "/bin/pwd", send: "", options: .init(timeout: 3, workingDirectory: dir))
        let clean = result.text.replacingOccurrences(of: "\r", with: "")
        #expect(clean.contains(dir.path))
    }

    @Test
    func `auto responds to trust prompt`() throws {
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
                timeout: 15,
                // Use LF for portability: some PTY/termios setups do not translate CR → NL for shell reads.
                sendOnSubstrings: ["trust the files in this folder?": "y\n"],
                stopOnSubstrings: ["accepted", "rejected"],
                settleAfterStop: 0.1))

        #expect(result.text.contains("accepted"))
    }

    @Test
    func `post-exit drain processes trailing chunk through callback path`() {
        let callbackCounter = CallbackCounter()
        var reads: [TTYCommandRunner.DrainReadResult] = [
            .wouldBlock,
            .wouldBlock,
            .data(Data("https://example.com/auth".utf8)),
            .closed,
        ]

        TTYCommandRunner.drainRemainingOutput(
            until: Date().addingTimeInterval(1),
            readChunk: {
                if reads.isEmpty { return .closed }
                return reads.removeFirst()
            },
            processChunk: { data in
                if data.range(of: Data("https://".utf8)) != nil {
                    callbackCounter.increment()
                }
            },
            sleep: { _ in })

        #expect(callbackCounter.value() == 1)
    }

    @Test
    func `post-exit drain keeps harvesting after late success marker`() {
        var readCount = 0
        var processedChunks: [String] = []
        var reads: [TTYCommandRunner.DrainReadResult] = [
            .data(Data("accepted".utf8)),
            .wouldBlock,
            .data(Data(" trailing".utf8)),
            .closed,
        ]

        TTYCommandRunner.drainRemainingOutput(
            until: Date().addingTimeInterval(1),
            readChunk: {
                readCount += 1
                if reads.isEmpty { return .closed }
                return reads.removeFirst()
            },
            processChunk: { data in
                processedChunks.append(String(bytes: data, encoding: .utf8) ?? "")
            },
            sleep: { _ in })

        #expect(readCount == 4)
        #expect(processedChunks == ["accepted", " trailing"])
    }

    @Test
    func `post-exit drain stops once the PTY reports closure`() {
        var readCount = 0

        TTYCommandRunner.drainRemainingOutput(
            until: Date().addingTimeInterval(1),
            readChunk: {
                readCount += 1
                return .closed
            },
            processChunk: { _ in },
            sleep: { _ in })

        #expect(readCount == 1)
    }

    @Test
    func `interrupted drain reads are treated as retryable`() {
        let result = TTYCommandRunner.drainReadResult(for: Data(), terminalRead: -1, errno: EINTR)
        if case .wouldBlock = result {
            #expect(Bool(true))
        } else {
            Issue.record("Expected interrupted read to remain retryable during drain")
        }
    }

    @Test
    func `EOF beats stale would-block errno during drain classification`() {
        let result = TTYCommandRunner.drainReadResult(for: Data(), terminalRead: 0, errno: EAGAIN)
        if case .closed = result {
            #expect(Bool(true))
        } else {
            Issue.record("Expected EOF reads to stop draining even if errno still holds EAGAIN")
        }
    }

    @Test
    func `stops when output is idle`() throws {
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
    func `rolling buffer detects needle across boundary`() {
        var scanner = TTYCommandRunner.RollingBuffer(maxNeedle: 6)
        let needle = Data("hello".utf8)
        let first = scanner.append(Data("he".utf8))
        #expect(first.range(of: needle) == nil)
        let second = scanner.append(Data("llo!".utf8))
        #expect(second.range(of: needle) != nil)
    }

    @Test
    func `lowercased ASCII only touches ascii`() {
        let data = Data("UpDaTe".utf8)
        let lowered = TTYCommandRunner.lowercasedASCII(data)
        #expect(String(data: lowered, encoding: .utf8) == "update")
    }
}
