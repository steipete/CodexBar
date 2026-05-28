import CodexBarCore
import Testing
@testable import CodexBarCLI

struct CLIDiagnoseCommandTests {
    @Test
    func `diagnose help describes generic JSON export`() {
        let help = CodexBarCLI.diagnoseHelp(version: "0.0.0")

        #expect(help.contains("codexbar diagnose --provider <name|all> --format json"))
        #expect(help.contains("codexbar diagnose --provider all --format json"))
        #expect(help.contains("safe JSON export"))
        #expect(help.contains("raw API tokens"))
    }

    private func makeSettingsWithMiniMaxCookie(_ manualCookieHeader: String) -> ProviderSettingsSnapshot {
        ProviderSettingsSnapshot(
            debugMenuEnabled: false,
            debugKeepCLISessionsAlive: false,
            codex: nil,
            claude: nil,
            cursor: nil,
            opencode: nil,
            opencodego: nil,
            alibaba: nil,
            factory: nil,
            minimax: ProviderSettingsSnapshot.MiniMaxProviderSettings(
                cookieSource: .manual,
                manualCookieHeader: manualCookieHeader,
                apiRegion: .global),
            manus: nil,
            zai: nil,
            copilot: nil,
            kilo: nil,
            kimi: nil,
            augment: nil,
            amp: nil,
            ollama: nil)
    }

    @Test
    func `diagnose auth mode uses settings-backed MiniMax manual cookie when env token is absent`() {
        let settings = self.makeSettingsWithMiniMaxCookie("Cookie: session_id=demo-cookie")

        let authMode = CodexBarCLI._resolveMiniMaxAuthModeForTesting(
            environment: [:],
            settings: settings)

        #expect(authMode == .cookie)
    }

    @Test
    func `diagnose auth mode keeps apiToken precedence over settings cookie`() {
        let settings = self.makeSettingsWithMiniMaxCookie("Cookie: session_id=demo-cookie")

        let authMode = CodexBarCLI._resolveMiniMaxAuthModeForTesting(
            environment: [MiniMaxAPISettingsReader.apiTokenKey: "sk-api-demo-token"],
            settings: settings)

        #expect(authMode == .apiToken)
    }

    @Test
    func `generic diagnose auth summary detects provider config`() {
        let summary = CodexBarCLI._diagnosticAuthSummaryForTesting(
            provider: .openai,
            account: nil,
            config: ProviderConfig(id: .openai, apiKey: "sk-test"),
            environment: [:],
            settings: nil)

        #expect(summary.configured)
        #expect(summary.modes == ["api"])
    }

    @Test
    func `generic diagnose auth summary detects provider environment credentials`() {
        let summary = CodexBarCLI._diagnosticAuthSummaryForTesting(
            provider: .openai,
            account: nil,
            config: nil,
            environment: [OpenAIAPISettingsReader.apiKeyEnvironmentKey: "sk-test"],
            settings: nil)

        #expect(summary.configured)
        #expect(summary.modes == ["api"])
    }

    @Test
    func `generic diagnose auth summary requires complete Bedrock credentials`() {
        let partial = CodexBarCLI._diagnosticAuthSummaryForTesting(
            provider: .bedrock,
            account: nil,
            config: ProviderConfig(id: .bedrock, apiKey: "access-only"),
            environment: [BedrockSettingsReader.accessKeyIDKey: "access-only"],
            settings: nil)
        #expect(!partial.configured)
        #expect(partial.modes.isEmpty)

        let complete = CodexBarCLI._diagnosticAuthSummaryForTesting(
            provider: .bedrock,
            account: nil,
            config: nil,
            environment: [
                BedrockSettingsReader.accessKeyIDKey: "access",
                BedrockSettingsReader.secretAccessKeyKey: "secret",
            ],
            settings: nil)
        #expect(complete.configured)
        #expect(complete.modes == ["api"])
    }

    @Test
    func `generic diagnose auth summary does not assume ambient credentials`() {
        let summary = CodexBarCLI._diagnosticAuthSummaryForTesting(
            provider: .codex,
            account: nil,
            config: nil,
            environment: [:],
            settings: nil)

        #expect(!summary.configured)
        #expect(summary.modes.isEmpty)
    }
}
