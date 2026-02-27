import Foundation

public struct PerplexityCookieOverride: Sendable {
    public let token: String

    public init(token: String) {
        self.token = token
    }
}

public enum PerplexityCookieHeader {
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
            return PerplexityCookieOverride(token: raw)
        }

        // Extract __Secure-next-auth.session-token from a full cookie string
        if let token = self.extractSessionToken(from: raw) {
            return PerplexityCookieOverride(token: token)
        }

        return nil
    }

    private static func extractSessionToken(from raw: String) -> String? {
        let key = "__Secure-next-auth.session-token="
        guard let keyRange = raw.range(of: key, options: .caseInsensitive) else { return nil }
        let rest = raw[keyRange.upperBound...]
        let value = rest.prefix(while: { $0 != ";" && !$0.isWhitespace })
        let token = String(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
