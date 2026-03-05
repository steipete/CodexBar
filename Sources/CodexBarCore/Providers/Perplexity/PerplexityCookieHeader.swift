import Foundation

public struct PerplexityCookieOverride: Sendable {
    public let name: String
    public let token: String

    public init(name: String, token: String) {
        self.name = name
        self.token = token
    }
}

public enum PerplexityCookieHeader {
    public static let defaultSessionCookieName = "__Secure-next-auth.session-token"
    public static let supportedSessionCookieNames = [
        "__Secure-next-auth.session-token",
        "next-auth.session-token",
        "__Secure-authjs.session-token",
        "authjs.session-token",
    ]

    public static func resolveCookieOverride(context: ProviderFetchContext) -> PerplexityCookieOverride? {
        if let settings = context.settings?.perplexity, settings.cookieSource == .manual {
            if let manual = settings.manualCookieHeader, !manual.isEmpty {
                return self.override(from: manual)
            }
        }
        return nil
    }

    public static func override(from raw: String?) -> PerplexityCookieOverride? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        // Accept bare token value
        if !raw.contains("=") && !raw.contains(";") {
            return PerplexityCookieOverride(name: self.defaultSessionCookieName, token: raw)
        }

        // Extract a supported session cookie from a full cookie string.
        if let cookie = self.extractSessionCookie(from: raw) {
            return cookie
        }

        return nil
    }

    private static func extractSessionCookie(from raw: String) -> PerplexityCookieOverride? {
        let pairs = raw.split(separator: ";")
        var cookieMap: [String: (name: String, value: String)] = [:]
        for pair in pairs {
            let trimmed = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            cookieMap[key.lowercased()] = (name: key, value: value)
        }

        for expected in self.supportedSessionCookieNames {
            if let match = cookieMap[expected.lowercased()] {
                return PerplexityCookieOverride(name: match.name, token: match.value)
            }
        }
        return nil
    }
}
