import CodexBarCore
import Testing

struct DeepInfraSettingsReaderTests {
    @Test
    func `reads DEEPINFRA_API_KEY`() {
        let env = ["DEEPINFRA_API_KEY": "di-primary"]
        #expect(DeepInfraSettingsReader.apiKey(environment: env) == "di-primary")
    }

    @Test
    func `falls back to DEEPINFRA_TOKEN`() {
        let env = ["DEEPINFRA_TOKEN": "di-fallback"]
        #expect(DeepInfraSettingsReader.apiKey(environment: env) == "di-fallback")
    }

    @Test
    func `primary key takes precedence and is cleaned`() {
        let env = [
            "DEEPINFRA_API_KEY": "  \"di-primary\"  ",
            "DEEPINFRA_TOKEN": "di-fallback",
        ]
        #expect(DeepInfraSettingsReader.apiKey(environment: env) == "di-primary")
    }

    @Test
    func `returns nil when keys are empty`() {
        let env = ["DEEPINFRA_API_KEY": "   ", "DEEPINFRA_TOKEN": ""]
        #expect(DeepInfraSettingsReader.apiKey(environment: env) == nil)
    }
}

struct DeepInfraProviderTokenResolverTests {
    @Test
    func `resolves DeepInfra key from environment`() {
        let resolution = ProviderTokenResolver.deepInfraResolution(
            environment: ["DEEPINFRA_API_KEY": "di-resolve"])
        #expect(resolution?.token == "di-resolve")
        #expect(resolution?.source == .environment)
    }

    @Test
    func `descriptor registers API strategy and branding`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .deepinfra)
        #expect(descriptor.metadata.displayName == "DeepInfra")
        #expect(descriptor.metadata.dashboardURL == "https://deepinfra.com/dash")
        #expect(descriptor.metadata.statusLinkURL == "https://status.deepinfra.com")
        #expect(descriptor.branding.iconResourceName == "ProviderIcon-deepinfra")
        #expect(descriptor.branding.confettiPalette.count == 3)
        #expect(descriptor.branding.confettiPalette[0] != descriptor.branding.confettiPalette[1])
        #expect(descriptor.fetchPlan.sourceModes == Set([.auto, .api]))
    }

    @Test
    func `provider config projects API key into environment`() {
        let environment = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .deepinfra,
            config: ProviderConfig(id: .deepinfra, apiKey: "config-token"))
        #expect(environment[DeepInfraSettingsReader.apiKeyEnvironmentKey] == "config-token")
    }
}
