import CryptoKit
import Foundation

public struct OAuthAuthorizationRequest: Sendable {
    public let url: URL
    public let state: String
    public let codeVerifier: String

    public init(url: URL, state: String, codeVerifier: String) {
        self.url = url
        self.state = state
        self.codeVerifier = codeVerifier
    }
}

public enum OAuthSupport {
    public static func randomURLSafeString(length: Int = 64) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0 ..< length).map { _ in
            alphabet.randomElement(using: &generator) ?? "A"
        })
    }

    public static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    public static func formEncodedBody(_ items: [URLQueryItem]) -> Data {
        var components = URLComponents()
        components.queryItems = items
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    public static func queryValue(named name: String, in url: URL) -> String? {
        if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
        {
            return value
        }

        guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment,
              !fragment.isEmpty
        else {
            return nil
        }

        var fragmentComponents = URLComponents()
        fragmentComponents.percentEncodedQuery = fragment
        return fragmentComponents.queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    public static func decodedJWTPayload(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let parts = token.split(separator: ".", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        guard let payload = Data(base64URLEncoded: String(parts[1])) else { return nil }
        return try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
    }

    public static func parseISO8601Date(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    public static func parseScopes(_ scopeString: String?) -> [String] {
        guard let scopeString else { return [] }
        return scopeString
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var padded = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 {
            padded.append("=")
        }
        guard let data = Data(base64Encoded: padded) else { return nil }
        self = data
    }
}
