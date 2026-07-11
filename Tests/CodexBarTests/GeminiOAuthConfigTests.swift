import CodexBarCore
import Foundation
import Testing

@Suite(.serialized)
struct GeminiOAuthConfigTests {
    @Test
    func `environment client requires both id and secret`() {
        let values = GeminiOAuthConfig.EnvironmentValues(clientID: "env-id", clientSecret: nil)
        GeminiOAuthConfig.$environmentOverride.withValue(values) {
            #expect(GeminiOAuthConfig.environmentClient() == nil)
        }
    }

    @Test
    func `environment client returns configured credentials`() {
        let values = GeminiOAuthConfig.EnvironmentValues(
            clientID: "env-id",
            clientSecret: "env-secret")
        GeminiOAuthConfig.$environmentOverride.withValue(values) {
            let resolved = GeminiOAuthConfig.environmentClient()
            #expect(resolved?.clientID == "env-id")
            #expect(resolved?.clientSecret == "env-secret")
        }
    }
}
