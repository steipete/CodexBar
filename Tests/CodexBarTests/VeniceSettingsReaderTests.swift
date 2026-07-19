import CodexBarCore
import Testing

struct VeniceSettingsReaderTests {
    @Test
    func `reads VENICE_API_KEY`() {
        let env = ["VENICE_API_KEY": "ven-abc123"]
        #expect(VeniceSettingsReader.apiKey(environment: env) == "ven-abc123")
    }

    @Test
    func `falls back to VENICE_KEY`() {
        let env = ["VENICE_KEY": "ven-fallback"]
        #expect(VeniceSettingsReader.apiKey(environment: env) == "ven-fallback")
    }

    @Test
    func `VENICE_API_KEY takes priority over VENICE_KEY`() {
        let env = ["VENICE_API_KEY": "ven-primary", "VENICE_KEY": "ven-secondary"]
        #expect(VeniceSettingsReader.apiKey(environment: env) == "ven-primary")
    }

    @Test
    func `trims whitespace`() {
        let env = ["VENICE_API_KEY": "  ven-trimmed  "]
        #expect(VeniceSettingsReader.apiKey(environment: env) == "ven-trimmed")
    }

    @Test
    func `strips double quotes`() {
        let env = ["VENICE_API_KEY": "\"ven-quoted\""]
        #expect(VeniceSettingsReader.apiKey(environment: env) == "ven-quoted")
    }

    @Test
    func `strips single quotes`() {
        let env = ["VENICE_KEY": "'ven-single'"]
        #expect(VeniceSettingsReader.apiKey(environment: env) == "ven-single")
    }

    @Test
    func `returns nil when no key present`() {
        #expect(VeniceSettingsReader.apiKey(environment: [:]) == nil)
    }

    @Test
    func `returns nil for empty key`() {
        let env = ["VENICE_API_KEY": ""]
        #expect(VeniceSettingsReader.apiKey(environment: env) == nil)
    }

    @Test
    func `returns nil for whitespace-only key`() {
        let env = ["VENICE_API_KEY": "   "]
        #expect(VeniceSettingsReader.apiKey(environment: env) == nil)
    }
}

struct VeniceProviderTokenResolverTests {
    @Test
    func `resolves from environment`() {
        let env = ["VENICE_API_KEY": "ven-resolve-test"]
        let resolution = ProviderTokenResolver.veniceResolution(environment: env)
        #expect(resolution?.token == "ven-resolve-test")
        #expect(resolution?.source == .environment)
    }

    @Test
    func `returns nil when key absent`() {
        let resolution = ProviderTokenResolver.veniceResolution(environment: [:])
        #expect(resolution == nil)
    }
}
