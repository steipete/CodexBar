import CodexBarCore
import Testing

struct PoeProviderDescriptorTests {
    @Test
    func `Poe uses the official brand color and icon`() {
        let branding = PoeProviderDescriptor.descriptor.branding

        #expect(branding.iconResourceName == "ProviderIcon-poe")
        #expect(branding.color == ProviderColor(red: 93 / 255, green: 92 / 255, blue: 222 / 255))
    }
}
