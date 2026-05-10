import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class ProviderHTTPClient: @unchecked Sendable {
    public static let shared = ProviderHTTPClient()

    private let queue = DispatchQueue(label: "com.steipete.CodexBar.provider-http-client")
    private var session: URLSession
    private var proxy: NetworkProxyConfiguration?
    private var password: String?

    public init() {
        self.proxy = nil
        self.password = nil
        self.session = URLSession(configuration: Self.makeSessionConfiguration(proxy: nil, password: nil))
    }

    public func update(proxy: NetworkProxyConfiguration?, password: String?) {
        let configuration = Self.makeSessionConfiguration(proxy: proxy, password: password)
        let session = URLSession(configuration: configuration)
        self.queue.sync {
            self.proxy = proxy
            self.password = password
            self.session = session
        }
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let session = self.queue.sync { self.session }
        return try await session.data(for: request)
    }

    public func currentProxyConfiguration() -> NetworkProxyConfiguration? {
        self.queue.sync { self.proxy }
    }

    public func currentPassword() -> String? {
        self.queue.sync { self.password }
    }

    public static func makeSessionConfiguration(
        proxy: NetworkProxyConfiguration?,
        password: String?) -> URLSessionConfiguration
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60

        guard let proxy, proxy.isActive, let port = proxy.resolvedPort else {
            return configuration
        }

        let trimmedPassword = password?.trimmingCharacters(in: .whitespacesAndNewlines)
        var proxyDictionary: [String: Any] = [:]
        switch proxy.scheme {
        case .http:
            proxyDictionary[ProxyDictionaryKey.httpEnable] = 1
            proxyDictionary[ProxyDictionaryKey.httpProxy] = proxy.trimmedHost
            proxyDictionary[ProxyDictionaryKey.httpPort] = port
            proxyDictionary[ProxyDictionaryKey.httpsEnable] = 1
            proxyDictionary[ProxyDictionaryKey.httpsProxy] = proxy.trimmedHost
            proxyDictionary[ProxyDictionaryKey.httpsPort] = port
        case .socks5:
            proxyDictionary[ProxyDictionaryKey.socksEnable] = 1
            proxyDictionary[ProxyDictionaryKey.socksProxy] = proxy.trimmedHost
            proxyDictionary[ProxyDictionaryKey.socksPort] = port
        }

        if !proxy.trimmedUsername.isEmpty {
            proxyDictionary[proxy.scheme == .http ? ProxyDictionaryKey.httpUser : ProxyDictionaryKey.socksUser] =
                proxy.trimmedUsername
        }
        if let trimmedPassword, !trimmedPassword.isEmpty {
            proxyDictionary[proxy.scheme == .http ? ProxyDictionaryKey.httpPassword : ProxyDictionaryKey.socksPassword] =
                trimmedPassword
        }

        configuration.connectionProxyDictionary = proxyDictionary
        return configuration
    }
}

private enum ProxyDictionaryKey {
    static let httpEnable = "HTTPEnable"
    static let httpProxy = "HTTPProxy"
    static let httpPort = "HTTPPort"
    static let httpsEnable = "HTTPSEnable"
    static let httpsProxy = "HTTPSProxy"
    static let httpsPort = "HTTPSPort"
    static let socksEnable = "SOCKSEnable"
    static let socksProxy = "SOCKSProxy"
    static let socksPort = "SOCKSPort"
    static let httpUser = "HTTPUser"
    static let httpPassword = "HTTPPassword"
    static let socksUser = "SOCKSUser"
    static let socksPassword = "SOCKSPassword"
}
