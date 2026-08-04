import CodexBarCore
import Foundation
import Testing

struct ProviderConfigByteStabilityTests {
    @Test(arguments: [
        "provider-specific-full",
        "provider-specific-sparse",
    ])
    func `current provider config fixtures re-encode byte for byte`(fixtureName: String) throws {
        let fixtureURL = try #require(Bundle.module.url(
            forResource: fixtureName,
            withExtension: "json",
            subdirectory: "Fixtures/Config"))
        let fixtureData = try Data(contentsOf: fixtureURL)
        let config = try JSONDecoder().decode(CodexBarConfig.self, from: fixtureData)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(config)

        // Text fixtures keep the repository-standard final newline; JSONEncoder intentionally does not emit one.
        #expect(Data(fixtureData.dropLast()) == encoded)
    }
}
