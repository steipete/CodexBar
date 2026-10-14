import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

extension ProviderSettingsDescriptorTests {
    @Test
    func `Command Code keeps its API key and source in provider config`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-commandcode")
        let context = fixture.settingsContext(provider: .commandcode)
        let implementation = CommandCodeProviderImplementation()
        let pickers = implementation.settingsPickers(context: context)
        let source = try #require(pickers.first { $0.id == "commandcode-usage-source" })
        let cookies = try #require(pickers.first { $0.id == "commandcode-cookie-source" })
        let fields = implementation.settingsFields(context: context)
        let key = try #require(fields.first { $0.id == "commandcode-api-key" })
        #expect(source.binding.wrappedValue == "auto")
        #expect(key.isVisible?() == true)
        #expect(source.options.map(\.id) == ["auto", "api", "web"])
        source.binding.wrappedValue = "api"
        key.binding.wrappedValue = "fixture-command-key"
        #expect(fixture.settings.providerConfig(for: .commandcode)?.apiKey == "fixture-command-key")
        #expect(fixture.settings.providerConfig(for: .commandcode)?.source == .api)
        #expect(cookies.isVisible?() == false)
        #expect(key.isVisible?() == true)
        source.binding.wrappedValue = "web"
        #expect(key.isVisible?() == false)
        #expect(cookies.isVisible?() == true)
    }
}
