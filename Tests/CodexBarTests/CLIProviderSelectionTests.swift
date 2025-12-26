import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

@Suite
struct CLIProviderSelectionTests {
    @Test
    func helpIncludesGeminiAndAll() {
        let usage = CodexBarCLI.usageHelp(version: "0.0.0")
        let root = CodexBarCLI.rootHelp(version: "0.0.0")
        #expect(usage.contains("codex|claude|zai|gemini|antigravity|both|all"))
        #expect(root.contains("codex|claude|zai|gemini|antigravity|both|all"))
        #expect(usage.contains("codexbar usage --provider gemini"))
        #expect(usage.contains("codexbar usage --format json --provider all --pretty"))
        #expect(root.contains("codexbar --provider gemini"))
    }

    @Test
    func helpMentionsSourceFlag() {
        let usage = CodexBarCLI.usageHelp(version: "0.0.0")
        let root = CodexBarCLI.rootHelp(version: "0.0.0")

        func tokens(_ text: String) -> [String] {
            let split = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "[]|,"))
            return text.components(separatedBy: split).filter { !$0.isEmpty }
        }

        #expect(usage.contains("--source"))
        #expect(root.contains("--source"))
        #expect(usage.contains("--web-timeout"))
        #expect(usage.contains("--web-debug-dump-html"))
        #expect(!tokens(usage).contains("--web"))
        #expect(!tokens(root).contains("--web"))
        #expect(!tokens(usage).contains("--claude-source"))
        #expect(!tokens(root).contains("--claude-source"))
    }

    @Test
    func providerSelectionRespectsOverride() {
        let selection = CodexBarCLI.providerSelection(rawOverride: "gemini", enabled: [.codex, .claude])
        #expect(selection.asList == [.gemini])
    }

    @Test
    func providerSelectionUsesAllWhenEnabled() {
        let selection = CodexBarCLI.providerSelection(
            rawOverride: nil,
            enabled: [.codex, .claude, .zai, .cursor, .gemini, .antigravity])
        #expect(selection.asList == [.codex, .claude, .zai, .cursor, .gemini, .antigravity])
    }

    @Test
    func providerSelectionUsesBothForCodexAndClaude() {
        let selection = CodexBarCLI.providerSelection(rawOverride: nil, enabled: [.codex, .claude])
        #expect(selection.asList == [.codex, .claude])
    }

    @Test
    func providerSelectionUsesCustomForCodexAndGemini() {
        let enabled: [UsageProvider] = [.codex, .gemini]
        let selection = CodexBarCLI.providerSelection(rawOverride: nil, enabled: enabled)
        #expect(selection.asList == enabled)
    }

    @Test
    func providerSelectionDefaultsToCodexWhenEmpty() {
        let selection = CodexBarCLI.providerSelection(rawOverride: nil, enabled: [])
        #expect(selection.asList == [.codex])
    }
}
