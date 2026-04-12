import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

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
        #expect(dictionary[kCFNetworkProxiesHTTPEnable as String] as? Int == 1)
        #expect(dictionary[kCFNetworkProxiesHTTPProxy as String] as? String == "proxy.example.com")
        #expect(dictionary[kCFNetworkProxiesHTTPPort as String] as? Int == 8080)
        #expect(dictionary[kCFNetworkProxiesHTTPSEnable as String] as? Int == 1)
        #expect(dictionary[kCFNetworkProxiesHTTPSProxy as String] as? String == "proxy.example.com")
        #expect(dictionary[kCFNetworkProxiesHTTPSPort as String] as? Int == 8080)
        #expect(dictionary[kCFProxyUsernameKey as String] as? String == "alice")
        #expect(dictionary[kCFProxyPasswordKey as String] as? String == "secret")
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
        #expect(dictionary[kCFNetworkProxiesSOCKSEnable as String] as? Int == 1)
        #expect(dictionary[kCFNetworkProxiesSOCKSProxy as String] as? String == "proxy.example.com")
        #expect(dictionary[kCFNetworkProxiesSOCKSPort as String] as? Int == 1080)
        #expect(dictionary[kCFProxyUsernameKey as String] as? String == "alice")
        #expect(dictionary[kCFProxyPasswordKey as String] as? String == "secret")
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
}
