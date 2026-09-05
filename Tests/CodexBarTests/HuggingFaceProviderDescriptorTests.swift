import CodexBarCore
import Testing
@testable import CodexBar

struct HuggingFaceProviderDescriptorTests {
    @Test
    func `automatic browser cookie imports use Chrome only`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .huggingface)

        #if os(macOS)
        #expect(descriptor.metadata.browserCookieOrder == [.chrome])
        #else
        #expect(descriptor.metadata.browserCookieOrder == nil)
        #endif
    }
}
