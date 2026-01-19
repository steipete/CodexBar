import CodexBarCore
import Testing

@Suite
struct KimiK2SettingsReaderTests {
    @Test
    func apiKeyIsTrimmed() {
        let env = ["KIMI_API_KEY": "  key-123  "]
        #expect(KimiK2SettingsReader.apiKey(environment: env) == "key-123")
    }

    @Test
    func apiKeyStripsQuotes() {
        let env = ["KIMI_KEY": "\"quoted-456\""]
        #expect(KimiK2SettingsReader.apiKey(environment: env) == "quoted-456")
    }
}

@Suite
struct KimiK2ProviderTokenResolverTests {
    @Test
    func resolvesFromEnvironment() {
        let env = ["KIMI_API_KEY": "env-token"]
        let resolution = ProviderTokenResolver.kimiK2Resolution(environment: env)
        #expect(resolution?.token == "env-token")
        #expect(resolution?.source == .environment)
    }
}
