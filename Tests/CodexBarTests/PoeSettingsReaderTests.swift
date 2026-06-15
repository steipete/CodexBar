import CodexBarCore
import Foundation
import Testing

struct PoeSettingsReaderTests {
    @Test
    func `api key trims quotes`() {
        let env = [PoeSettingsReader.apiKeyEnvironmentKey: " 'poe-key' "]
        #expect(PoeSettingsReader.apiKey(environment: env) == "poe-key")
    }
}
