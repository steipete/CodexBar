import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct TTYCommandRunnerEnvTests {
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
                timeout: 3,
                sendOnSubstrings: ["Do you trust the files in this folder?": "y\r"],
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
        sleep 10
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let runner = TTYCommandRunner()
        let startedAt = Date()
        let result = try runner.run(
            binary: scriptURL.path,
            send: "",
            options: .init(timeout: 6, idleTimeout: 0.2))
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(result.text.contains("hello"))
        #expect(elapsed < 3.0)
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
