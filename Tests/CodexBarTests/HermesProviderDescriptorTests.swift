import Testing
@testable import CodexBarCore

struct HermesProviderDescriptorTests {
    @Test
    func `Hermes is available to the cost command`() {
        #expect(HermesProviderDescriptor.descriptor.cli.supportsCostCommand)
    }
}
