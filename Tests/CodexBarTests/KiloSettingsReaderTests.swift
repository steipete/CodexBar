import CodexBarCore
import Testing

struct KiloSettingsReaderTests {
    @Test
    func `api URL defaults to app kilo AI trpc`() {
        let url = KiloSettingsReader.apiURL(environment: [:])

        #expect(url.scheme == "https")
        #expect(url.host() == "app.kilo.ai")
        #expect(url.path == "/api/trpc")
    }

    @Test
    func `api URL ignores environment override`() {
        let url = KiloSettingsReader.apiURL(environment: ["KILO_API_URL": "https://proxy.example.com/trpc"])

        #expect(url.host() == "app.kilo.ai")
        #expect(url.path == "/api/trpc")
    }

    @Test
    func `descriptor uses app kilo AI dashboard`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .kilo)
        #expect(descriptor.metadata.dashboardURL == "https://app.kilo.ai/usage")
    }

    @Test
    func `descriptor uses dedicated kilo icon resource`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .kilo)
        #expect(descriptor.branding.iconResourceName == "ProviderIcon-kilo")
    }

    @Test
    func `descriptor supports auto API and CLI source modes`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .kilo)
        let expected: Set<ProviderSourceMode> = [.auto, .api, .cli]
        #expect(descriptor.fetchPlan.sourceModes == expected)
    }
}
