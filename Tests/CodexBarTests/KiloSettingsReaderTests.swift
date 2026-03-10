import CodexBarCore
import Testing

@Suite
struct KiloSettingsReaderTests {
    @Test
    func apiURLDefaultsToAppKiloAITrpc() {
        let url = KiloSettingsReader.apiURL(environment: [:])

        #expect(url.scheme == "https")
        #expect(url.host() == "app.kilo.ai")
        #expect(url.path == "/api/trpc")
    }

    @Test
    func apiURLIgnoresEnvironmentOverride() {
        let url = KiloSettingsReader.apiURL(environment: ["KILO_API_URL": "https://proxy.example.com/trpc"])

        #expect(url.host() == "app.kilo.ai")
        #expect(url.path == "/api/trpc")
    }

    @Test
    func descriptorUsesAppKiloAIDashboard() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .kilo)
        #expect(descriptor.metadata.dashboardURL == "https://app.kilo.ai/account/usage")
    }

    @Test
    func descriptorUsesDedicatedKiloIconResource() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .kilo)
        #expect(descriptor.branding.iconResourceName == "ProviderIcon-kilo")
    }

    @Test
    func descriptorSupportsAutoAPIAndCLISourceModes() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .kilo)
        let expected: Set<ProviderSourceMode> = [.auto, .api, .cli]
        #expect(descriptor.fetchPlan.sourceModes == expected)
    }
}
