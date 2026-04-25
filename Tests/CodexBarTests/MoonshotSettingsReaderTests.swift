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

    // MARK: - Kimi CLI config parsing

    @Test
    func `parseKimiConfigAPIKey extracts key from managed moonshot section`() {
        let toml = """
        [providers."managed:moonshot-ai"]
        type = "kimi"
        base_url = "https://api.moonshot.ai/v1"
        api_key = "sk-from-config"
        """

        #expect(MoonshotSettingsReader.parseKimiConfigAPIKey(toml) == "sk-from-config")
    }

    @Test
    func `parseKimiConfigAPIKey strips quotes`() {
        let toml = """
        [providers."managed:moonshot-ai"]
        api_key = 'sk-single-quoted'
        """

        #expect(MoonshotSettingsReader.parseKimiConfigAPIKey(toml) == "sk-single-quoted")
    }

    @Test
    func `parseKimiConfigAPIKey respects section boundaries`() {
        let toml = """
        [providers."managed:moonshot-ai"]
        type = "kimi"
        api_key = "sk-correct"

        [providers."other"]
        api_key = "sk-wrong"
        """

        #expect(MoonshotSettingsReader.parseKimiConfigAPIKey(toml) == "sk-correct")
    }

    @Test
    func `parseKimiConfigAPIKey ignores keys in other sections`() {
        let toml = """
        [providers."other"]
        api_key = "sk-wrong"

        [providers."managed:moonshot-ai"]
        api_key = "sk-correct"
        """

        #expect(MoonshotSettingsReader.parseKimiConfigAPIKey(toml) == "sk-correct")
    }

    @Test
    func `parseKimiConfigAPIKey ignores comments`() {
        let toml = """
        [providers."managed:moonshot-ai"]
        # api_key = "sk-commented"
        api_key = "sk-real"
        """

        #expect(MoonshotSettingsReader.parseKimiConfigAPIKey(toml) == "sk-real")
    }

    @Test
    func `parseKimiConfigAPIKey returns nil when section missing`() {
        let toml = """
        [other]
        api_key = "sk-wrong"
        """

        #expect(MoonshotSettingsReader.parseKimiConfigAPIKey(toml) == nil)
    }

    @Test
    func `parseKimiConfigAPIKey returns nil when key missing`() {
        let toml = """
        [providers."managed:moonshot-ai"]
        type = "kimi"
        """

        #expect(MoonshotSettingsReader.parseKimiConfigAPIKey(toml) == nil)
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
