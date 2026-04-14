import CodexBarCore
import Testing

struct MoonshotSettingsReaderTests {
    @Test
    func `api key prefers MOONSHOT API KEY`() {
        let env = [
            "MOONSHOT_API_KEY": "primary-token",
            "MOONSHOT_KEY": "fallback-token",
        ]

        #expect(MoonshotSettingsReader.apiKey(environment: env) == "primary-token")
    }

    @Test
    func `api key strips quotes`() {
        let env = ["MOONSHOT_KEY": "\"quoted-token\""]

        #expect(MoonshotSettingsReader.apiKey(environment: env) == "quoted-token")
    }

    @Test
    func `region parses china`() {
        let env = ["MOONSHOT_REGION": "china"]

        #expect(MoonshotSettingsReader.region(environment: env) == .china)
    }

    @Test
    func `region defaults to international for unknown values`() {
        let env = ["MOONSHOT_REGION": "moon"]

        #expect(MoonshotSettingsReader.region(environment: env) == .international)
    }
}

struct MoonshotProviderTokenResolverTests {
    @Test
    func `resolves from environment`() {
        let env = ["MOONSHOT_API_KEY": "env-token"]
        let resolution = ProviderTokenResolver.moonshotResolution(environment: env)

        #expect(resolution?.token == "env-token")
        #expect(resolution?.source == .environment)
    }
}
