import Foundation
import Testing
@testable import CodexBarCore

struct FireworksSettingsReaderTests {
    @Test
    func `config api key takes precedence over environment`() {
        let environment = [
            FireworksSettingsReader.configAPIKeyEnvironmentKey: "config-key",
            "FIREWORKS_API_KEY": "env-key",
        ]

        #expect(FireworksSettingsReader.apiKey(environment: environment) == "config-key")
    }

    @Test
    func `falls back through api key environment keys`() {
        #expect(
            FireworksSettingsReader.apiKey(
                environment: ["FIREWORKS_API_KEY": "env-key"]) == "env-key")
        #expect(
            FireworksSettingsReader.apiKey(
                environment: ["FIREWORKS_KEY": "legacy-key"]) == "legacy-key")
        #expect(
            FireworksSettingsReader.apiKey(environment: [:]) == nil)
    }

    @Test
    func `quoted and padded values are cleaned`() {
        let environment = [
            "FIREWORKS_API_KEY": "\"  fw-quoted-key  \"",
            FireworksSettingsReader.accountSlugEnvironmentKey: "' x0mh0x '",
        ]

        #expect(FireworksSettingsReader.apiKey(environment: environment) == "fw-quoted-key")
        #expect(FireworksSettingsReader.accountSlug(environment: environment) == "x0mh0x")
    }

    @Test
    func `config account slug takes precedence over environment`() {
        let environment = [
            FireworksSettingsReader.configAccountSlugEnvironmentKey: "config-slug",
            FireworksSettingsReader.accountSlugEnvironmentKey: "env-slug",
        ]

        #expect(FireworksSettingsReader.accountSlug(environment: environment) == "config-slug")
        #expect(
            FireworksSettingsReader.accountSlug(
                environment: [FireworksSettingsReader.accountSlugEnvironmentKey: "env-slug"])
                == "env-slug")
        #expect(FireworksSettingsReader.accountSlug(environment: [:]) == nil)
    }
}
