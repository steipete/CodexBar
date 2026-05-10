import CodexBarCore
import Foundation
import Testing
@testable import CodexBar
#if os(macOS)
import Security
#endif

final class FailingOnLoadProxyPasswordStore: NetworkProxyPasswordStoring, @unchecked Sendable {
    var value: String?
    var shouldFailOnLoad = false

    init(value: String? = nil) {
        self.value = value
    }

    func loadPassword() throws -> String? {
        if self.shouldFailOnLoad {
            struct LoadFailure: Error {}
            throw LoadFailure()
        }
        return self.value
    }

    func storePassword(_ password: String?) throws {
        self.value = password
    }
}

@Suite(.serialized)
@MainActor
struct NetworkProxyTests {
    @Test
    func `proxy settings persist without password in config file`() throws {
        let suite = "NetworkProxyTests-persist"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let proxyPasswordStore = InMemoryProxyPasswordStore()

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore(),
            networkProxyPasswordStore: proxyPasswordStore)

        settings.networkProxyEnabled = true
        #expect(settings.networkProxyEnabled == true)
        settings.networkProxyScheme = .socks5
        #expect(settings.networkProxyScheme == .socks5)
        settings.networkProxyHost = "proxy.example.com"
        #expect(settings.networkProxyHost == "proxy.example.com")
        settings.networkProxyPort = "1080"
        #expect(settings.networkProxyPort == "1080")
        settings.networkProxyUsername = "alice"
        #expect(settings.networkProxyUsername == "alice")
        settings.networkProxyPassword = "secret"
        #expect(settings.networkProxyPassword == "secret")

        let saved = try configStore.load()
        let proxy = try #require(saved?.networkProxy)
        #expect(proxy.enabled == true)
        #expect(proxy.scheme == .socks5)
        #expect(proxy.host == "proxy.example.com")
        #expect(proxy.port == "1080")
        #expect(proxy.username == "alice")
        #expect(String(data: try Data(contentsOf: configStore.fileURL), encoding: .utf8)?.contains("secret") == false)

        let reloaded = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore(),
            networkProxyPasswordStore: proxyPasswordStore)

        #expect(reloaded.networkProxyEnabled == true)
        #expect(reloaded.networkProxyScheme == .socks5)
        #expect(reloaded.networkProxyHost == "proxy.example.com")
        #expect(reloaded.networkProxyPort == "1080")
        #expect(reloaded.networkProxyUsername == "alice")
        #expect(reloaded.networkProxyPassword == "secret")
    }

    @Test
    func `http proxy session configuration includes auth and host`() throws {
        let proxy = NetworkProxyConfiguration(
            enabled: true,
            scheme: .http,
            host: "proxy.example.com",
            port: "8080",
            username: "alice")

        let configuration = ProviderHTTPClient.makeSessionConfiguration(
            proxy: proxy,
            password: "secret")

        let dictionary = try #require(configuration.connectionProxyDictionary as? [String: Any])
        #expect(dictionary["HTTPEnable"] as? Int == 1)
        #expect(dictionary["HTTPProxy"] as? String == "proxy.example.com")
        #expect(dictionary["HTTPPort"] as? Int == 8080)
        #expect(dictionary["HTTPSEnable"] as? Int == 1)
        #expect(dictionary["HTTPSProxy"] as? String == "proxy.example.com")
        #expect(dictionary["HTTPSPort"] as? Int == 8080)
        #expect(dictionary["HTTPUser"] as? String == "alice")
        #expect(dictionary["HTTPPassword"] as? String == "secret")
    }

    @Test
    func `socks5 proxy session configuration includes auth and host`() throws {
        let proxy = NetworkProxyConfiguration(
            enabled: true,
            scheme: .socks5,
            host: "proxy.example.com",
            port: "1080",
            username: "alice")

        let configuration = ProviderHTTPClient.makeSessionConfiguration(
            proxy: proxy,
            password: "secret")

        let dictionary = try #require(configuration.connectionProxyDictionary as? [String: Any])
        #expect(dictionary["SOCKSEnable"] as? Int == 1)
        #expect(dictionary["SOCKSProxy"] as? String == "proxy.example.com")
        #expect(dictionary["SOCKSPort"] as? Int == 1080)
        #expect(dictionary["SOCKSUser"] as? String == "alice")
        #expect(dictionary["SOCKSPassword"] as? String == "secret")
    }

    @Test
    func `proxy status text reflects active and inactive states`() throws {
        let suite = "NetworkProxyTests-status"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore(),
            networkProxyPasswordStore: InMemoryProxyPasswordStore())

        #expect(settings.networkProxyStatusText == "Proxy is off.")
        #expect(settings.networkProxyStatusIsActive == false)

        settings.networkProxyEnabled = true
        settings.networkProxyHost = "proxy.example.com"
        settings.networkProxyPort = "1080"

        #expect(settings.networkProxyStatusIsActive == true)
        #expect(
            settings.networkProxyStatusText
                == "Proxy is active and will route provider requests through proxy.example.com:1080.")
    }

    @Test
    func `proxy auth stays cached when password load fails during sync`() throws {
        ProviderHTTPClient.shared.update(proxy: nil, password: nil)
        defer { ProviderHTTPClient.shared.update(proxy: nil, password: nil) }

        let suite = "NetworkProxyTests-sync-password-cache"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let passwordStore = FailingOnLoadProxyPasswordStore()
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore(),
            networkProxyPasswordStore: passwordStore)

        settings.networkProxyEnabled = true
        settings.networkProxyHost = "proxy.example.com"
        settings.networkProxyPort = "8080"
        settings.networkProxyUsername = "alice"
        settings.networkProxyPassword = "secret"

        #expect(ProviderHTTPClient.shared.currentPassword() == "secret")
        #expect(ProviderHTTPClient.shared.currentProxyConfiguration()?.host == "proxy.example.com")

        passwordStore.shouldFailOnLoad = true
        settings.networkProxyHost = "proxy2.example.com"

        #expect(ProviderHTTPClient.shared.currentPassword() == "secret")
        #expect(ProviderHTTPClient.shared.currentProxyConfiguration()?.host == "proxy2.example.com")
    }

    #if os(macOS)
    @Test
    func `temporary keychain unavailability is treated as proxy password store failure`() {
        let store = KeychainNetworkProxyPasswordStore()

        KeychainCacheStore.withLoadFailureStatusOverrideForTesting(errSecInteractionNotAllowed) {
            do {
                _ = try store.loadPassword()
                #expect(Bool(false), "Expected proxy password load to fail")
            } catch NetworkProxyPasswordStoreError.keychainUnavailable {
                #expect(true)
            } catch {
                #expect(Bool(false), "Expected keychainUnavailable, got \(error)")
            }
        }
    }
    #endif
}
