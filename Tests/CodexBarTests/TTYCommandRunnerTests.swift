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

        let merged = TTYCommandRunner.enrichedEnvironment(baseEnv: baseEnv, home: "/Users/tester")

        #expect(merged["HOME"] == "/Users/tester")
        #expect(merged["LANG"] == "en_US.UTF-8")
        #expect(merged["TERM"] == "xterm-256color")

        let parts = (merged["PATH"] ?? "").split(separator: ":").map(String.init)
        #expect(parts.contains("/custom/bin"))
        #expect(parts.contains("/Users/tester/.bun/bin"))
    }

    @Test
    func backfillsHomeWhenMissing() {
        let merged = TTYCommandRunner.enrichedEnvironment(baseEnv: ["PATH": "/custom/bin"], home: "/Users/fallback")
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
}
