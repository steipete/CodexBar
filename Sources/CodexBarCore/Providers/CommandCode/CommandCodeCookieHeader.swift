import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A resolved CommandCode session cookie ready to be sent on `Cookie:` headers.
///
/// CommandCode's API (api.commandcode.ai) authenticates with the better-auth session
/// cookie set by commandcode.ai. better-auth emits either `better-auth.session_token`
/// or `__Secure-better-auth.session_token` depending on whether `useSecureCookies` is
/// enabled (the `__Secure-` variant is required by browsers for HTTPS production).
public struct CommandCodeCookieOverride: Sendable, Equatable {
    public let name: String
    public let token: String

    public init(name: String, token: String) {
        self.name = name
        self.token = token
    }

    /// `Cookie: name=value` header value.
    public var headerValue: String {
        "\(self.name)=\(self.token)"
    }
}

public enum CommandCodeCookieHeader {
    /// Cookie names used by better-auth in production (HTTPS) and dev (HTTP).
    /// The `__Secure-` variant is the standard production deployment.
    public static let supportedSessionCookieNames = [
        "__Host-better-auth.session_token",
        "__Secure-better-auth.session_token",
        "better-auth.session_token",
    ]

    /// Extract a session cookie from a list of `HTTPCookie` records.
    public static func sessionCookie(from cookies: [HTTPCookie]) -> CommandCodeCookieOverride? {
        let pairs = cookies.map { (name: $0.name, value: $0.value) }
        return self.extractSessionCookie(from: pairs)
    }

    /// Parse a raw `Cookie:` header (or bare token) and extract the session value.
    public static func override(from raw: String?) -> CommandCodeCookieOverride? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        // Bare token — assume the production cookie name.
        if !raw.contains("="), !raw.contains(";") {
            return CommandCodeCookieOverride(
                name: "__Secure-better-auth.session_token",
                token: raw)
        }

        return self.extractSessionCookie(fromHeader: raw)
    }

    private static func extractSessionCookie(fromHeader header: String) -> CommandCodeCookieOverride? {
        var pairs: [(name: String, value: String)] = []
        for chunk in header.split(separator: ";") {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            pairs.append((name: key, value: value))
        }
        return self.extractSessionCookie(from: pairs)
    }

    private static func extractSessionCookie(from pairs: [(name: String, value: String)])
    -> CommandCodeCookieOverride? {
        var byLowerName: [String: (name: String, value: String)] = [:]
        for pair in pairs {
            byLowerName[pair.name.lowercased()] = pair
        }
        for expected in self.supportedSessionCookieNames {
            if let match = byLowerName[expected.lowercased()] {
                return CommandCodeCookieOverride(name: match.name, token: match.value)
            }
        }
        return nil
    }
}
