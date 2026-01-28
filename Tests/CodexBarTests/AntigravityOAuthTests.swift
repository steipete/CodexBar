import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct AntigravityOAuthCredentialsTests {
    @Test
    func isExpired() {
        let expired = AntigravityOAuthCredentials(
            accessToken: "ya29.test",
            refreshToken: "1//refresh",
            expiresAt: Date().addingTimeInterval(-3600),
            email: "test@example.com")
        let valid = AntigravityOAuthCredentials(
            accessToken: "ya29.test",
            refreshToken: "1//refresh",
            expiresAt: Date().addingTimeInterval(3600),
            email: "test@example.com")
        #expect(expired.isExpired)
        #expect(!valid.isExpired)
    }

    @Test
    func needsRefreshWhenExpiringSoon() {
        let creds = AntigravityOAuthCredentials(
            accessToken: "ya29.test",
            refreshToken: "1//refresh",
            expiresAt: Date().addingTimeInterval(120),
            email: nil)
        #expect(creds.needsRefresh)
    }
}

@Suite(.serialized)
struct AntigravityOAuthCredentialsStoreTests {
    @Test
    func normalizesLabel() {
        let normalized = AntigravityOAuthCredentialsStore.normalizedLabel("  User@Example.com \n")
        #expect(normalized == "user@example.com")
    }

    @Test
    func saveAndLoadByLabel() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        let previousKeychainDisabled = KeychainAccessGate.isDisabled
        KeychainAccessGate.isDisabled = false
        defer { KeychainAccessGate.isDisabled = previousKeychainDisabled }
        AntigravityOAuthCredentialsStore.invalidateCache()

        let creds = AntigravityOAuthCredentials(
            accessToken: "ya29.test",
            refreshToken: "1//refresh",
            expiresAt: Date().addingTimeInterval(3600),
            email: "user@example.com")
        #expect(AntigravityOAuthCredentialsStore.save(creds, accountLabel: "User@Example.com"))

        let loaded = AntigravityOAuthCredentialsStore.load(accountLabel: "user@example.com")
        #expect(loaded?.accessToken == "ya29.test")
        #expect(loaded?.refreshToken == "1//refresh")
    }
}

@Suite
struct AntigravityManualTokenPayloadTests {
    @Test
    func parsesJSONPayload() {
        let token = AntigravityOAuthCredentialsStore.manualTokenValue(
            accessToken: "ya29.test",
            refreshToken: "1//refresh")
        let payload = AntigravityOAuthCredentialsStore.manualTokenPayload(from: token)
        #expect(payload?.accessToken == "ya29.test")
        #expect(payload?.refreshToken == "1//refresh")
    }

    @Test
    func parsesLegacyPayload() {
        let token = "\(AntigravityOAuthCredentialsStore.manualTokenPrefix)ya29.test"
        let payload = AntigravityOAuthCredentialsStore.manualTokenPayload(from: token)
        #expect(payload?.accessToken == "ya29.test")
        #expect(payload?.refreshToken == nil)
    }
}

@Suite
struct AntigravityUsageSourceTests {
    @Test
    func parsesRawValue() {
        #expect(AntigravityUsageSource(rawValue: "cli") == .local)
        #expect(AntigravityUsageSource(rawValue: "authorized") == .authorized)
    }
}

@Suite(.serialized)
struct AntigravityAuthorizedFetchStrategyTests {
    private func makeContext(usageSource: AntigravityUsageSource, accountLabel: String?) -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        let settings = ProviderSettingsSnapshot(
            debugMenuEnabled: false,
            debugKeepCLISessionsAlive: false,
            codex: nil,
            claude: nil,
            cursor: nil,
            opencode: nil,
            factory: nil,
            minimax: nil,
            zai: nil,
            copilot: nil,
            kimi: nil,
            augment: nil,
            amp: nil,
            jetbrains: nil,
            antigravity: .init(usageSource: usageSource, accountLabel: accountLabel))
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: settings,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    @Test
    func unavailableWithoutAccountLabel() async {
        let strategy = AntigravityAuthorizedFetchStrategy()
        let context = self.makeContext(usageSource: .auto, accountLabel: nil)
        let available = await strategy.isAvailable(context)
        #expect(!available)
    }

    @Test
    func availableWithStoredCredentials() async {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        let previousKeychainDisabled = KeychainAccessGate.isDisabled
        KeychainAccessGate.isDisabled = false
        defer { KeychainAccessGate.isDisabled = previousKeychainDisabled }
        AntigravityOAuthCredentialsStore.invalidateCache()

        let creds = AntigravityOAuthCredentials(
            accessToken: "ya29.test",
            refreshToken: "1//refresh",
            expiresAt: Date().addingTimeInterval(3600),
            email: "user@example.com")
        _ = AntigravityOAuthCredentialsStore.save(creds, accountLabel: "user@example.com")

        let strategy = AntigravityAuthorizedFetchStrategy()
        let context = self.makeContext(usageSource: .auto, accountLabel: "user@example.com")
        let available = await strategy.isAvailable(context)
        #expect(available)
    }

    @Test
    func fallbackInAutoMode() {
        let strategy = AntigravityAuthorizedFetchStrategy()
        let context = self.makeContext(usageSource: .auto, accountLabel: "user@example.com")
        let shouldFallback = strategy.shouldFallback(
            on: AntigravityOAuthCredentialsError.networkError("test"),
            context: context)
        #expect(shouldFallback)
    }

    @Test
    func noFallbackOnNetworkErrorInOAuthMode() {
        let strategy = AntigravityAuthorizedFetchStrategy()
        let context = self.makeContext(usageSource: .authorized, accountLabel: "user@example.com")
        let shouldFallback = strategy.shouldFallback(
            on: AntigravityOAuthCredentialsError.networkError("test"),
            context: context)
        #expect(!shouldFallback)
    }
}
