import CodexBarCore
import Testing

struct DeepSeekSettingsReaderTests {
    @Test
    func `reads DEEPSEEK_API_KEY`() {
        let env = ["DEEPSEEK_API_KEY": "sk-abc123"]
        #expect(DeepSeekSettingsReader.apiKey(environment: env) == "sk-abc123")
    }

    @Test
    func `falls back to DEEPSEEK_KEY`() {
        let env = ["DEEPSEEK_KEY": "sk-fallback"]
        #expect(DeepSeekSettingsReader.apiKey(environment: env) == "sk-fallback")
    }

    @Test
    func `DEEPSEEK_API_KEY takes priority over DEEPSEEK_KEY`() {
        let env = ["DEEPSEEK_API_KEY": "sk-primary", "DEEPSEEK_KEY": "sk-secondary"]
        #expect(DeepSeekSettingsReader.apiKey(environment: env) == "sk-primary")
    }

    @Test
    func `trims whitespace`() {
        let env = ["DEEPSEEK_API_KEY": "  sk-trimmed  "]
        #expect(DeepSeekSettingsReader.apiKey(environment: env) == "sk-trimmed")
    }

    @Test
    func `strips double quotes`() {
        let env = ["DEEPSEEK_API_KEY": "\"sk-quoted\""]
        #expect(DeepSeekSettingsReader.apiKey(environment: env) == "sk-quoted")
    }

    @Test
    func `strips single quotes`() {
        let env = ["DEEPSEEK_KEY": "'sk-single'"]
        #expect(DeepSeekSettingsReader.apiKey(environment: env) == "sk-single")
    }

    @Test
    func `returns nil when no key present`() {
        #expect(DeepSeekSettingsReader.apiKey(environment: [:]) == nil)
    }

    @Test
    func `returns nil for empty key`() {
        let env = ["DEEPSEEK_API_KEY": ""]
        #expect(DeepSeekSettingsReader.apiKey(environment: env) == nil)
    }

    @Test
    func `returns nil for whitespace-only key`() {
        let env = ["DEEPSEEK_API_KEY": "   "]
        #expect(DeepSeekSettingsReader.apiKey(environment: env) == nil)
    }
}

struct DeepSeekProviderTokenResolverTests {
    @Test
    func `resolves from environment`() {
        let env = ["DEEPSEEK_API_KEY": "sk-resolve-test"]
        let resolution = ProviderTokenResolver.deepseekResolution(environment: env)
        #expect(resolution?.token == "sk-resolve-test")
        #expect(resolution?.source == .environment)
    }

    @Test
    func `returns nil when key absent`() {
        let resolution = ProviderTokenResolver.deepseekResolution(environment: [:])
        #expect(resolution == nil)
    }
}
