import Foundation
import Testing
@testable import CodexBarCore

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
    func `reads separate platform session token`() {
        let env = ["DEEPSEEK_PLATFORM_TOKEN": "  browser-session-token  "]
        #expect(DeepSeekSettingsReader.platformToken(environment: env) == "browser-session-token")
    }

    @Test
    func `falls back to DeepSeek user token environment key`() {
        let env = ["DEEPSEEK_USER_TOKEN": "browser-user-token"]
        #expect(DeepSeekSettingsReader.platformToken(environment: env) == "browser-user-token")
    }

    @Test
    func `platform session token requires the active credential scope`() throws {
        let accountID = UUID()
        let credential = "api-key-value"
        let scope = try #require(DeepSeekSettingsReader.profileScope(
            selectedTokenAccountID: accountID,
            apiKey: credential))
        let environment = [
            DeepSeekSettingsReader.platformTokenEnvironmentKey: "platform-session",
            DeepSeekSettingsReader.profileScopeEnvironmentKey: scope,
        ]

        #expect(DeepSeekSettingsReader.scopedPlatformToken(
            environment: environment,
            selectedTokenAccountID: accountID,
            apiKey: credential) == "platform-session")
        #expect(DeepSeekSettingsReader.scopedPlatformToken(
            environment: environment,
            selectedTokenAccountID: UUID(),
            apiKey: credential) == nil)
        #expect(DeepSeekSettingsReader.scopedPlatformToken(
            environment: [DeepSeekSettingsReader.platformTokenEnvironmentKey: "platform-session"],
            selectedTokenAccountID: accountID,
            apiKey: credential) == nil)
        #expect(DeepSeekSettingsReader.scopedPlatformToken(
            environment: [DeepSeekSettingsReader.platformTokenEnvironmentKey: "platform-session"],
            selectedTokenAccountID: nil,
            apiKey: nil) == "platform-session")
    }

    @Test
    func `reads selected Chrome profile id`() {
        let env = [DeepSeekSettingsReader.profileIDEnvironmentKey: "  /profiles/Profile 2  "]
        #expect(DeepSeekSettingsReader.profileID(environment: env) == "chrome:Profile 2")
    }

    @Test
    func `migrates an absolute Chrome profile path to a stable identifier`() {
        let environment = [
            DeepSeekSettingsReader.profileIDEnvironmentKey:
                "/Users/example/Library/Application Support/Google/Chrome/Profile 2",
        ]

        #expect(DeepSeekSettingsReader.profileID(environment: environment) == "chrome:Profile 2")
    }

    @Test
    func `profile scope fingerprints the api credential without storing it`() throws {
        let accountID = UUID()
        let first = try #require(DeepSeekSettingsReader.profileScope(
            selectedTokenAccountID: accountID,
            apiKey: "secret-api-key"))
        let repeated = try #require(DeepSeekSettingsReader.profileScope(
            selectedTokenAccountID: accountID,
            apiKey: "secret-api-key"))
        let replacedKey = try #require(DeepSeekSettingsReader.profileScope(
            selectedTokenAccountID: accountID,
            apiKey: "replacement-api-key"))
        let otherAccount = try #require(DeepSeekSettingsReader.profileScope(
            selectedTokenAccountID: UUID(),
            apiKey: "secret-api-key"))

        #expect(first == repeated)
        #expect(first != replacedKey)
        #expect(first != otherAccount)
        #expect(!first.contains("secret-api-key"))
    }

    @Test
    func `browser only profile scope persists without an API key`() throws {
        let scope = try #require(DeepSeekSettingsReader.profileScope(
            selectedTokenAccountID: nil,
            apiKey: nil))

        #expect(!scope.isEmpty)
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
