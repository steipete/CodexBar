import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct WayfinderProviderTests {
    @Test
    @MainActor
    func `descriptor and implementation are registered`() throws {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .wayfinder)
        #expect(descriptor.metadata.displayName == "Wayfinder")
        #expect(descriptor.metadata.cliName == "wayfinder")
        #expect(descriptor.cli.aliases.contains("wayfinder-router"))
        #expect(!descriptor.metadata.defaultEnabled)
        #expect(descriptor.branding.iconResourceName == "ProviderIcon-wayfinder")

        let implementation = try #require(ProviderImplementationRegistry.implementation(for: .wayfinder))
        #expect(implementation.id == .wayfinder)
    }
}
