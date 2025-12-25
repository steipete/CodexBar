import CodexBarCore
import Testing
@testable import CodexBarCLI

@Suite
struct CLIProviderSelectionTests {
    @Test
    func helpIncludesGeminiAndAll() {
        let usage = CodexBarCLI.usageHelp(version: "0.0.0")
        let root = CodexBarCLI.rootHelp(version: "0.0.0")
        #expect(usage.contains("codex|claude|gemini|antigravity|both|all"))
        #expect(root.contains("codex|claude|gemini|antigravity|both|all"))
        #expect(usage.contains("codexbar usage --provider gemini"))
        #expect(usage.contains("codexbar usage --format json --provider all --pretty"))
        #expect(root.contains("codexbar --provider gemini"))
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
            enabled: [.codex, .claude, .gemini, .antigravity, .cursor])
        #expect(selection.asList == [.codex, .claude, .gemini, .antigravity, .cursor])
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
