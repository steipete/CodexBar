import CodexBarCore
import Testing

struct KimiK2SettingsReaderTests {
    @Test
    func `api key is trimmed`() {
        let env = ["KIMI_API_KEY": "  key-123  "]
        #expect(KimiK2SettingsReader.apiKey(environment: env) == "key-123")
    }

    @Test
    func `api key strips quotes`() {
        let env = ["KIMI_KEY": "\"quoted-456\""]
        #expect(KimiK2SettingsReader.apiKey(environment: env) == "quoted-456")
    }
}

struct KimiK2ProviderTokenResolverTests {
    @Test
    func `resolves from environment`() {
        let env = ["KIMI_API_KEY": "env-token"]
        let resolution = ProviderTokenResolver.kimiK2Resolution(environment: env)
        #expect(resolution?.token == "env-token")
        #expect(resolution?.source == .environment)
    }
}
