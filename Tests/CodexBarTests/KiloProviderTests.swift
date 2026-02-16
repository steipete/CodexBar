import CodexBarCore
import Testing

@Suite
struct KiloSettingsReaderTests {
    @Test
    func readsTokenFromEnvironmentVariable() {
        let env = ["KILO_API_KEY": "test-api-key"]
        let token = KiloSettingsReader.apiToken(environment: env)
        #expect(token == "test-api-key")
    }

    @Test
    func returnsNilWhenMissing() {
        let env: [String: String] = [:]
        let token = KiloSettingsReader.apiToken(environment: env)
        #expect(token == nil)
    }

    @Test
    func apiTokenStripsQuotes() {
        let env = ["KILO_API_KEY": "\"quoted-token\""]
        let token = KiloSettingsReader.apiToken(environment: env)
        #expect(token == "quoted-token")
    }

    @Test
    func normalizesQuotedToken() {
        let env = ["KILO_API_KEY": "'single-quoted'"]
        let token = KiloSettingsReader.apiToken(environment: env)
        #expect(token == "single-quoted")
    }
}

@Suite
struct KiloTokenResolverTests {
    @Test
    func resolvesTokenFromEnvironment() {
        let env = ["KILO_API_KEY": "test-api-key"]
        let token = ProviderTokenResolver.kiloToken(environment: env)
        #expect(token == "test-api-key")
    }

    @Test
    func returnsNilWhenMissing() {
        let env: [String: String] = [:]
        let token = ProviderTokenResolver.kiloToken(environment: env)
        #expect(token == nil)
    }
}
