import CodexBarCore
import Testing
@testable import CodexBarCLI

struct CLIDiagnoseCommandTests {
    @Test
    func `diagnose help describes minimax JSON export`() {
        let help = CodexBarCLI.diagnoseHelp(version: "0.0.0")

        #expect(help.contains("codexbar diagnose --provider minimax --format json"))
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
}
