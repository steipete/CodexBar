import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A parsed, validated outbound proxy configuration applied globally to ``ProviderHTTPClient``.
///
/// Authentication is intentionally unsupported: credentials embedded in the URL are ignored.
public struct ProxyConfiguration: Sendable, Equatable {
    public enum ProxyType: Sendable, Equatable {
        case http
        case socks
    }

    public let type: ProxyType
    public let host: String
    public let port: Int

    public init(type: ProxyType, host: String, port: Int) {
        self.type = type
        self.host = host
        self.port = port
    }

    /// Parses a proxy URL such as `http://127.0.0.1:8080` or `socks5://127.0.0.1:1080`.
    /// Any user-info component is ignored — proxy authentication is not supported.
    public static func parse(from urlString: String) throws -> ProxyConfiguration {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProxyConfigurationError.empty }

        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), !scheme.isEmpty
        else {
            throw ProxyConfigurationError.badScheme("")
        }

        let type: ProxyType
        let defaultPort: Int
        switch scheme {
        case "http", "https":
            type = .http
            defaultPort = 8080
        case "socks", "socks5":
            type = .socks
            defaultPort = 1080
        default:
            throw ProxyConfigurationError.badScheme(scheme)
        }

        guard let host = components.host, !host.isEmpty else {
            throw ProxyConfigurationError.badHost
        }

        let port = components.port ?? defaultPort
        guard (1...65535).contains(port) else { throw ProxyConfigurationError.badPort }

        return ProxyConfiguration(type: type, host: host, port: port)
    }

    /// The `URLSessionConfiguration.connectionProxyDictionary` representation.
    ///
    /// For an HTTP proxy both the HTTP and HTTPS keys are set to the same host/port, because nearly all
    /// provider endpoints are `https://`.
    public func connectionProxyDictionary() -> [AnyHashable: Any] {
        #if os(Linux)
        // Linux/CLI relies on http_proxy/https_proxy environment variables instead.
        return [:]
        #else
        switch self.type {
        case .http:
            return [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: self.host,
                kCFNetworkProxiesHTTPPort as String: self.port,
                kCFNetworkProxiesHTTPSEnable as String: true,
                kCFNetworkProxiesHTTPSProxy as String: self.host,
                kCFNetworkProxiesHTTPSPort as String: self.port,
            ]
        case .socks:
            return [
                kCFNetworkProxiesSOCKSEnable as String: true,
                kCFNetworkProxiesSOCKSProxy as String: self.host,
                kCFNetworkProxiesSOCKSPort as String: self.port,
            ]
        }
        #endif
    }
}

public enum ProxyConfigurationError: LocalizedError, Equatable {
    case empty
    case badScheme(String)
    case badHost
    case badPort

    public var errorDescription: String? {
        switch self {
        case .empty:
            "Proxy URL is empty."
        case let .badScheme(scheme):
            scheme.isEmpty
                ? "Proxy URL is missing a scheme. Use http://, https://, or socks5://."
                : "Unsupported proxy scheme “\(scheme)”. Use http://, https://, or socks5://."
        case .badHost:
            "Proxy URL is missing a valid host."
        case .badPort:
            "Proxy URL has an invalid port."
        }
    }
}
