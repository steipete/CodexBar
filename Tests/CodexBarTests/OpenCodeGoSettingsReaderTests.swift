import CodexBarCore
import Testing

struct OpenCodeGoSettingsReaderTests {
    @Test
    func `reads and normalizes API key`() {
        #expect(OpenCodeGoSettingsReader.apiKey(environment: ["OPENCODE_API_KEY": "  go_test  "]) == "go_test")
        #expect(OpenCodeGoSettingsReader.apiKey(environment: ["OPENCODE_API_KEY": "'go_quoted'"]) == "go_quoted")
        #expect(OpenCodeGoSettingsReader.apiKey(environment: ["OPENCODE_API_KEY": "  "]) == nil)
    }

    @Test
    func `descriptor exposes API source and config override`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .opencodego)

        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api, .web])
        #expect(descriptor.credentials?.supportsAPIKeyOverride == true)
    }
}
