import CodexBarCore
import Foundation
import Testing

struct PoeSettingsReaderTests {
    @Test
    func `oauth api key trims quotes`() {
        let env = [PoeSettingsReader.oauthAPIKeyEnvironmentKey: " 'oauth-key' "]
        #expect(PoeSettingsReader.oauthAPIKey(environment: env) == "oauth-key")
    }

    @Test
    func `oauth api key expiry parses unix timestamp`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let env = [PoeSettingsReader.oauthAPIKeyExpiresAtEnvironmentKey: "1699999999"]
        #expect(PoeSettingsReader.oauthAPIKeyIsExpired(environment: env, now: now))
    }

    @Test
    func `oauth api key expiry parses iso8601`() {
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let env = [PoeSettingsReader.oauthAPIKeyExpiresAtEnvironmentKey: "2023-11-15T00:00:00Z"]
        #expect(PoeSettingsReader.oauthAPIKeyIsExpired(environment: env, now: now))
    }

    @Test
    func `oauth api key uses expires in fallback`() {
        let envExpired = [PoeSettingsReader.oauthAPIKeyExpiresInEnvironmentKey: "0"]
        let envValid = [PoeSettingsReader.oauthAPIKeyExpiresInEnvironmentKey: "120"]

        #expect(PoeSettingsReader.oauthAPIKeyIsExpired(environment: envExpired))
        #expect(!PoeSettingsReader.oauthAPIKeyIsExpired(environment: envValid))
    }
}
