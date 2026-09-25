import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

extension ProviderSettingsDescriptorTests {
    @Test
    func `provider breakdown toggles default off and persist independently`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-breakdowns")
        for (provider, implementation, toggleID, environmentKey) in [
            (
                UsageProvider.claude,
                ClaudeProviderImplementation() as any ProviderImplementation,
                "claude-workspace-spend",
                "ANTHROPIC_ADMIN_WORKSPACE_SPEND"),
            (
                UsageProvider.litellm,
                LiteLLMProviderImplementation() as any ProviderImplementation,
                "litellm-model-usage",
                "LITELLM_MODEL_USAGE_ENABLED"),
        ] {
            let toggle = try #require(implementation.settingsToggles(
                context: fixture.settingsContext(provider: provider)).first { $0.id == toggleID })
            #expect(!toggle.binding.wrappedValue)
            toggle.binding.wrappedValue = true
            let config = try #require(fixture.settings.providerConfig(for: provider))
            let restored = try JSONDecoder().decode(ProviderConfig.self, from: JSONEncoder().encode(config))
            let env = ProviderConfigEnvironment.applyProviderConfigOverrides(
                base: [:], provider: provider, config: restored)
            #expect(env[environmentKey] == "true")
            toggle.binding.wrappedValue = false
            #expect(!toggle.binding.wrappedValue)
        }
    }
}
