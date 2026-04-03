import CodexBarCore
import Testing
@testable import CodexBar

struct ActiveAppDetectorTests {
    @Test
    func `provider maps expected exact and prefix bundle identifiers`() {
        let cases: [(bundleID: String, expected: UsageProvider?)] = [
            // Codex
            ("com.openai.codex", .codex),
            ("com.openai.codex.desktop", .codex),
            // Claude
            ("com.anthropic.claude", .claude),
            ("com.anthropic.claude-2", .claude),
            // Copilot (VS Code and JetBrains)
            ("com.microsoft.VSCode", .copilot),
            ("com.microsoft.VSCodeInsiders", .copilot),
            ("com.jetbrains.intellij", .copilot),
            // Ollama
            ("com.electron.ollama", .ollama),
            ("com.ollama", .ollama),
            ("com.ollama.desktop", .ollama),
            // Unknown
            ("com.apple.Safari", nil),
        ]

        for testCase in cases {
            #expect(ActiveAppDetector.provider(for: testCase.bundleID) == testCase.expected)
        }
    }

    @Test
    func `provider returns nil for unknown bundle identifier`() {
        #expect(ActiveAppDetector.provider(for: "com.example.unknown-ai-app") == nil)
    }
}
