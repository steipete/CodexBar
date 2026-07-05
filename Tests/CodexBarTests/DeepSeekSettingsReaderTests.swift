import CodexBarCore
import Testing
@testable import CodexBarCLI

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

    @Test
    func `reads platform session env`() {
        let env = ["DEEPSEEK_COOKIE": "session=abc"]
        #expect(DeepSeekSettingsReader.platformSession(environment: env) == "session=abc")
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

    @Test
    func `resolves platform cookie from environment`() {
        let env = ["DEEPSEEK_PLATFORM_SESSION": "Bearer eyJ.test"]
        let resolution = ProviderTokenResolver.deepseekCookieResolution(environment: env)
        #expect(resolution?.token == "Bearer eyJ.test")
        #expect(resolution?.source == .environment)
    }
}

struct DeepSeekCLISettingsSnapshotTests {
    @Test
    func `CLI snapshot includes configured deepseek cookie settings`() throws {
        let config = CodexBarConfig(providers: [
            ProviderConfig(
                id: .deepseek,
                cookieSource: .manual,
                cookieHeader: "session=manual"),
        ])
        let tokenContext = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: config,
            verbose: false)
        let snapshot = try #require(tokenContext.settingsSnapshot(for: .deepseek, account: nil))
        let deepseek = try #require(snapshot.deepseek)

        #expect(deepseek.cookieSource == .manual)
        #expect(deepseek.manualCookieHeader == "session=manual")
    }

    @Test
    func `CLI snapshot honors deepseek cookie source off`() throws {
        let config = CodexBarConfig(providers: [
            ProviderConfig(
                id: .deepseek,
                cookieSource: .off,
                cookieHeader: "session=ignored"),
        ])
        let tokenContext = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: config,
            verbose: false)
        let snapshot = try #require(tokenContext.settingsSnapshot(for: .deepseek, account: nil))
        let deepseek = try #require(snapshot.deepseek)

        #expect(deepseek.cookieSource == .off)
        #expect(deepseek.manualCookieHeader == "session=ignored")
    }
}
