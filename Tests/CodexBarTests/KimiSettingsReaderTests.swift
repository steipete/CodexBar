import CodexBarCore
import Testing

@Suite
struct KimiSettingsReaderTests {
    @Test
    func apiKeyIsTrimmed() {
        let env = ["KIMI_API_KEY": "  key-123  "]
        #expect(KimiSettingsReader.apiKey(environment: env) == "key-123")
    }

    @Test
    func apiKeyStripsQuotes() {
        let env = ["KIMI_KEY": "\"quoted-456\""]
        #expect(KimiSettingsReader.apiKey(environment: env) == "quoted-456")
    }
}

@Suite
struct KimiProviderTokenResolverTests {
    @Test
    func resolvesFromEnvironment() {
        let env = ["KIMI_API_KEY": "env-token"]
        let resolution = ProviderTokenResolver.kimiResolution(environment: env)
        #expect(resolution?.token == "env-token")
        #expect(resolution?.source == .environment)
    }
}
