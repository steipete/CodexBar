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
            proxyDictionary[kCFNetworkProxiesHTTPEnable as String] = 1
            proxyDictionary[kCFNetworkProxiesHTTPProxy as String] = proxy.trimmedHost
            proxyDictionary[kCFNetworkProxiesHTTPPort as String] = port
            proxyDictionary[kCFNetworkProxiesHTTPSEnable as String] = 1
            proxyDictionary[kCFNetworkProxiesHTTPSProxy as String] = proxy.trimmedHost
            proxyDictionary[kCFNetworkProxiesHTTPSPort as String] = port
        case .socks5:
            proxyDictionary[kCFNetworkProxiesSOCKSEnable as String] = 1
            proxyDictionary[kCFNetworkProxiesSOCKSProxy as String] = proxy.trimmedHost
            proxyDictionary[kCFNetworkProxiesSOCKSPort as String] = port
        }

        if !proxy.trimmedUsername.isEmpty {
            proxyDictionary[kCFProxyUsernameKey as String] = proxy.trimmedUsername
        }
        if let trimmedPassword, !trimmedPassword.isEmpty {
            proxyDictionary[kCFProxyPasswordKey as String] = trimmedPassword
        }

        configuration.connectionProxyDictionary = proxyDictionary
        return configuration
    }
}
