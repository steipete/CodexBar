import Foundation

public enum NetworkProxyScheme: String, CaseIterable, Codable, Sendable {
    case http
    case socks5

    public var displayName: String {
        switch self {
        case .http: "HTTP"
        case .socks5: "SOCKS5"
        }
    }
}

public struct NetworkProxyConfiguration: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var scheme: NetworkProxyScheme
    public var host: String
    public var port: String
    public var username: String

    public init(
        enabled: Bool,
        scheme: NetworkProxyScheme,
        host: String,
        port: String,
        username: String)
    {
        self.enabled = enabled
        self.scheme = scheme
        self.host = host
        self.port = port
        self.username = username
    }

    public var trimmedHost: String {
        self.host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedPort: String {
        self.port.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedUsername: String {
        self.username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var resolvedPort: Int? {
        guard let port = Int(self.trimmedPort), (1...65535).contains(port) else { return nil }
        return port
    }

    public var isActive: Bool {
        self.enabled && !self.trimmedHost.isEmpty && self.resolvedPort != nil
    }
}
