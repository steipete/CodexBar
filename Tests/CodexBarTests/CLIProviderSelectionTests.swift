import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIProviderSelectionTests {
    @Test
    func `help includes gemini and all`() {
        let usage = CodexBarCLI.usageHelp(version: "0.0.0")
        let root = CodexBarCLI.rootHelp(version: "0.0.0")
        let expectedProviders = [
            "--provider codex|",
            "|claude|",
            "|factory|",
            "|zai|",
            "|cursor|",
            "|gemini|",
            "|antigravity|",
            "|copilot|",
            "|synthetic|",
            "|kiro|",
            "|warp|",
            "|ollama|",
            "|devpass|",
            "|atlascloud|",
            "|vercel|",
            "|llmman|",
            "|aixy|",
            "|raycast|",
            "|xkiro|",
            "|museai|",
            "|lithosai|",
            "|workbuddy|",
            "|tavily|",
            "|linkup|",
            "|tinyapi|",
            "|exa|",
            "|cosmic|",
            "|aerostack|",
            "|sailresearch|",
            "|sofya|",
            "|fal|",
            "|flora|",
            "|parallel|",
            "|siliconflow|",
            "|claudeplatform|",
            "|munito|",
            "|soniox|",
            "|traecn|",
            "|chatbox|",
            "|abliteration|",
            "|tripo|",
            "|both|",
            "|all]",
        ]
        for provider in expectedProviders {
            #expect(usage.contains(provider))
            #expect(root.contains(provider))
        }
        #expect(usage.contains("--json"))
        #expect(root.contains("--json"))
        #expect(usage.contains("--json-only"))
        #expect(root.contains("--json-only"))
        #expect(usage.contains("--json-output"))
        #expect(root.contains("--json-output"))
        #expect(usage.contains("--log-level"))
        #expect(root.contains("--log-level"))
        #expect(usage.contains("--verbose"))
        #expect(root.contains("--verbose"))
        #expect(usage.contains("codexbar usage --provider gemini"))
        #expect(usage.contains("codexbar usage --format json --provider all --pretty"))
        #expect(root.contains("codexbar --provider gemini"))
    }

    @Test
    func `help mentions source flag`() {
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
    func `help advertises the toon output format`() {
        let usage = CodexBarCLI.usageHelp(version: "0.0.0")
        let root = CodexBarCLI.rootHelp(version: "0.0.0")

        #expect(usage.contains("--format text|json|toon"))
        #expect(root.contains("--format text|json|toon"))
        #expect(usage.contains("codexbar usage --format toon"))
        #expect(root.contains("codexbar --format toon"))
    }

    @Test
    func `provider selection respects override`() throws {
        let selection = try CodexBarCLI.providerSelection(rawOverride: "gemini", enabled: [.codex, .claude])
        #expect(selection.asList == [.gemini])
    }

    @Test
    func `provider selection uses enabled providers when three or more are enabled`() throws {
        let selection = try CodexBarCLI.providerSelection(
            rawOverride: nil,
            enabled: [.codex, .claude, .zai, .cursor, .gemini, .antigravity, .factory, .copilot])
        #expect(selection.asList == [.codex, .claude, .zai, .cursor, .gemini, .antigravity, .factory, .copilot])
    }

    @Test
    func `provider selection does not expand three enabled providers to all providers`() throws {
        let enabled: [UsageProvider] = [.codex, .claude, .copilot]
        let selection = try CodexBarCLI.providerSelection(rawOverride: nil, enabled: enabled)
        #expect(selection.asList == enabled)
        #expect(!selection.asList.contains(.gemini))
    }

    @Test
    func `provider selection uses both for codex and claude`() throws {
        let selection = try CodexBarCLI.providerSelection(rawOverride: nil, enabled: [.codex, .claude])
        #expect(selection.asList == [.codex, .claude])
    }

    @Test
    func `provider selection uses custom for codex and gemini`() throws {
        let enabled: [UsageProvider] = [.codex, .gemini]
        let selection = try CodexBarCLI.providerSelection(rawOverride: nil, enabled: enabled)
        #expect(selection.asList == enabled)
    }

    @Test
    func `provider selection accepts kiro alias`() throws {
        let selection = try CodexBarCLI.providerSelection(rawOverride: "kiro-cli", enabled: [.codex])
        #expect(selection.asList == [.kiro])
    }

    @Test
    func `provider selection accepts claude platform alias`() throws {
        let selection = try CodexBarCLI.providerSelection(rawOverride: "claude-platform", enabled: [.claude])
        #expect(selection.asList == [.claudeplatform])
    }

    @Test
    func `provider selection honors empty enabled set`() throws {
        let selection = try CodexBarCLI.providerSelection(rawOverride: nil, enabled: [])
        #expect(selection.asList == [])
    }

    @Test
    func `unknown explicit provider is an argument error naming the value`() {
        #expect {
            try CodexBarCLI.providerSelection(rawOverride: "not-a-real-provider", enabled: [.codex])
        } throws: { error in
            guard let error = error as? CLIArgumentError else { return false }
            return error.message.contains("'not-a-real-provider'") && error.message.contains("codex")
        }
    }

    @Test
    func `unknown explicit provider does not fall back when nothing is enabled`() {
        #expect(throws: CLIArgumentError.self) {
            try CodexBarCLI.providerSelection(rawOverride: "nope", enabled: [])
        }
    }

    @Test
    func `both and all stay valid explicit selections`() throws {
        #expect(try CodexBarCLI.providerSelection(rawOverride: "both", enabled: []).asList.count >= 1)
        #expect(try CodexBarCLI.providerSelection(rawOverride: "ALL", enabled: [.codex]).asList.count > 1)
    }

    @Test
    func `default selection ignores overrides`() {
        #expect(CodexBarCLI.defaultProviderSelection(enabled: [.codex]).asList == [.codex])
    }
}
