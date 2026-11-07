import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

@MainActor
struct TripoProviderTests {
    @Test
    func `Tripo is an opt in balance provider using the shared API key field`() throws {
        let descriptor = TripoProviderDescriptor.descriptor
        #expect(!descriptor.metadata.defaultEnabled)
        #expect(descriptor.metadata.balanceOnly)
        #expect(!descriptor.metadata.burnDownWidgetSelectable)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
        #expect(!descriptor.tokenCost.supportsTokenCost)
        #expect(ProviderSelection(argument: "tripo")?.asList == [.tripo])
        let config = ProviderConfig(id: .tripo, apiKey: "tripo_fixture")
        #expect(descriptor.credentials?.applyConfig(base: [:], config: config)["TRIPO_API_KEY"] == "tripo_fixture")
        let values = try #require(TripoProviderDescriptor.spec.scriptValues(
            ProviderCutoverTestSupport.context(environment: ["TRIPO_API_KEY": "tripo_fixture"])))
        let encoded = try #require(values.settings["MESSAGES"]?.data(using: .utf8))
        let messages = try JSONDecoder().decode([String: String].self, from: encoded)
        #expect(Set(messages.keys) == Set(TripoProviderDescriptor.diagnosticMessages))
        for message in TripoProviderDescriptor.diagnosticMessages {
            #expect(messages[message] == UsageFormatter.localized(message))
            #expect(L(message, language: "it") != message)
        }
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "TripoProviderTests")
        let implementation = try #require(ProviderCatalog.implementation(for: .tripo))
        let fields = implementation.settingsFields(context: fixture.settingsContext(provider: .tripo))
        #expect(fields.map(\.id) == ["tripo-api-key"])
        #expect(fields.map(\.kind) == [.secure])
        fields[0].binding.wrappedValue = "tripo_fixture"
        #expect(fixture.settings.providerConfig(for: .tripo)?.apiKey == "tripo_fixture")
    }
}
