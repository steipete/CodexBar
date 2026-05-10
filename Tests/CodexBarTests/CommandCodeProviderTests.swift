import CodexBarCore
import Testing
@testable import CodexBar

struct CommandCodeProviderTests {
    @Test
    func `descriptor metadata is correct`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .commandcode)

        #expect(descriptor.metadata.displayName == "Command Code")
        #expect(descriptor.metadata.dashboardURL == "https://commandcode.ai/studio")
        #expect(descriptor.metadata.subscriptionDashboardURL == "https://commandcode.ai/sixhobbits/settings/billing")
        #expect(descriptor.metadata.cliName == "commandcode")
        #expect(descriptor.branding.iconResourceName == "ProviderIcon-commandcode")
        #expect(descriptor.branding.iconStyle == .commandcode)
    }

    @MainActor
    @Test
    func `implementation is registered`() {
        #expect(ProviderCatalog.implementation(for: .commandcode) != nil)
    }
}
