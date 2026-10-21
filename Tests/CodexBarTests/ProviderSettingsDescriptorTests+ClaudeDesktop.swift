import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension ProviderSettingsDescriptorTests {
    @Test
    func `Claude desktop cookie source defaults off and persists independently of credentials`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-claude-desktop")
        let context = fixture.settingsContext(provider: .claude)
        let toggle = try #require(ClaudeProviderImplementation().settingsToggles(context: context).first {
            $0.id == "claude-desktop-cookies"
        })
        #expect(!toggle.binding.wrappedValue)
        toggle.binding.wrappedValue = true
        let picker = try #require(ClaudeProviderImplementation().settingsPickers(context: context).first {
            $0.id == "claude-cookie-source"
        })
        #expect(picker.trailingText?() == L("Claude desktop app"))
        #expect(fixture.settings.configSnapshot.providerConfig(for: .claude)?.claudeDesktopCookiesEnabled == true)
        #expect(fixture.settings.claudeSettingsSnapshot(tokenOverride: nil).desktopCookiesEnabled)
        let config = try #require(fixture.settings.configSnapshot.providerConfig(for: .claude))
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.claudeDesktopCookiesEnabled == true)
        let contribution = try #require(ClaudeProviderDescriptor.descriptor.settingsSection.credentialContribution(
            context: ProviderCredentialSettingsContext(config: config, account: nil)))
        #expect(ProviderSettingsSnapshot(contributions: [contribution]).claude?.desktopCookiesEnabled == true)
    }
}
