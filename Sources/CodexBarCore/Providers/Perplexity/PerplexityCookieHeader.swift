import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct PerplexityCookieOverride: Sendable {
    public let name: String
    public let token: String
    public let requestCookieNames: [String]

    public init(name: String, token: String, requestCookieNames: [String]? = nil) {
        self.name = name
        self.token = token
        self.requestCookieNames = requestCookieNames ?? [name]
    }
}

public enum PerplexityCookieHeader {
    public static let defaultSessionCookieName = "__Secure-next-auth.session-token"
    public static let supportedSessionCookieNames = [
        "__Secure-authjs.session-token",
        "authjs.session-token",
        "__Secure-next-auth.session-token",
        "next-auth.session-token",
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
        if !raw.contains("="), !raw.contains(";") {
            return PerplexityCookieOverride(
                name: self.defaultSessionCookieName,
                token: raw,
                requestCookieNames: self.supportedSessionCookieNames)
        }

        // Extract a supported session cookie from a full cookie string.
        if let cookie = self.extractSessionCookie(from: raw) {
            return cookie
        }

        return nil
    }

    static func sessionCookie(from cookies: [HTTPCookie]) -> PerplexityCookieOverride? {
        self.extractSessionCookie(from: cookies.map { (name: $0.name, value: $0.value) })
    }

    private static func extractSessionCookie(from raw: String) -> PerplexityCookieOverride? {
        let pairs = raw.split(separator: ";")
        var cookies: [(name: String, value: String)] = []
        for pair in pairs {
            let trimmed = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            cookies.append((name: key, value: value))
        }
        return self.extractSessionCookie(from: cookies)
    }

    private static func extractSessionCookie(from cookies: [(name: String, value: String)])
    -> PerplexityCookieOverride? {
        var cookieMap: [String: (name: String, value: String)] = [:]
        var chunkedCookies: [String: [Int: (name: String, value: String)]] = [:]

        for cookie in cookies {
            let loweredName = cookie.name.lowercased()
            cookieMap[loweredName] = cookie

            for expected in self.supportedSessionCookieNames {
                let loweredExpected = expected.lowercased()
                let prefix = "\(loweredExpected)."
                guard loweredName.hasPrefix(prefix) else { continue }
                let suffix = String(loweredName.dropFirst(prefix.count))
                guard let index = Int(suffix) else { continue }
                chunkedCookies[loweredExpected, default: [:]][index] = cookie
            }
        }

        for expected in self.supportedSessionCookieNames {
            let loweredExpected = expected.lowercased()
            if let match = cookieMap[loweredExpected] {
                return PerplexityCookieOverride(name: match.name, token: match.value)
            }
            if let chunked = self.reassembleChunkedSessionCookie(from: chunkedCookies[loweredExpected]) {
                return chunked
            }
        }
        return nil
    }

    private static func reassembleChunkedSessionCookie(
        from chunks: [Int: (name: String, value: String)]?) -> PerplexityCookieOverride?
    {
        guard let chunks,
              let firstChunk = chunks[0],
              let maxIndex = chunks.keys.max()
        else {
            return nil
        }

        var tokenParts: [String] = []
        tokenParts.reserveCapacity(maxIndex + 1)
        for index in 0...maxIndex {
            guard let chunk = chunks[index] else { return nil }
            tokenParts.append(chunk.value)
        }

        guard let suffixStart = firstChunk.name.lastIndex(of: ".") else { return nil }
        let baseName = String(firstChunk.name[..<suffixStart])
        return PerplexityCookieOverride(name: baseName, token: tokenParts.joined())
    }
}
