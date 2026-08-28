import Testing
@testable import CodexBar
@testable import CodexBarCore

struct ProviderDetectionPolicyTests {
    @Test
    func `fresh install detects Codex and Claude Desktop without unconfigured Gemini`() {
        let enabled = ProviderDetectionPolicy.enabledProviders(signals: .init(
            codexCLIInstalled: true,
            claudeCLIInstalled: false,
            claudeDesktopInstalled: true,
            geminiCLIInstalled: true,
            geminiConfigured: false,
            antigravityAvailable: false))

        #expect(enabled == [.codex, .claude])
    }

    @Test
    func `configured Gemini CLI is detected`() {
        let enabled = ProviderDetectionPolicy.enabledProviders(signals: .init(
            codexCLIInstalled: false,
            claudeCLIInstalled: false,
            claudeDesktopInstalled: false,
            geminiCLIInstalled: true,
            geminiConfigured: true,
            antigravityAvailable: false))

        #expect(enabled == [.gemini])
    }

    @Test
    func `Codex remains the fallback when no provider source is available`() {
        let enabled = ProviderDetectionPolicy.enabledProviders(signals: .init(
            codexCLIInstalled: false,
            claudeCLIInstalled: false,
            claudeDesktopInstalled: false,
            geminiCLIInstalled: false,
            geminiConfigured: false,
            antigravityAvailable: false))

        #expect(enabled == [.codex])
    }
}
