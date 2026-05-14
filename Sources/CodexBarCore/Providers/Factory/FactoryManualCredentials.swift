import Foundation

extension FactoryStatusProbe {
    struct ManualCredentials {
        let cookieHeader: String?
        let bearerToken: String?
    }

    static func manualCredentials(from raw: String?) -> ManualCredentials? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let normalizedCookieHeader = CookieHeaderNormalizer.normalize(raw)
        let cookieHeader = normalizedCookieHeader.flatMap {
            CookieHeaderNormalizer.pairs(from: $0).isEmpty ? nil : $0
        }
        let bearerToken = self.authorizationBearerToken(from: raw)
            ?? normalizedCookieHeader.flatMap(self.bearerToken(fromHeader:))
            ?? self.bareBearerToken(from: raw)
        guard cookieHeader != nil || bearerToken != nil else { return nil }
        return ManualCredentials(cookieHeader: cookieHeader, bearerToken: bearerToken)
    }

    static func bearerToken(fromHeader cookieHeader: String) -> String? {
        for pair in CookieHeaderNormalizer.pairs(from: cookieHeader) where pair.name == "access-token" {
            let token = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { return token }
        }
        return nil
    }

    private static func authorizationBearerToken(from raw: String) -> String? {
        let pattern = #"(?i)(?:authorization\s*:\s*)?bearer\s+([A-Za-z0-9._~+/=-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, options: [], range: range),
              match.numberOfRanges >= 2,
              let tokenRange = Range(match.range(at: 1), in: raw)
        else {
            return nil
        }
        let token = raw[tokenRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : String(token)
    }

    private static func bareBearerToken(from raw: String) -> String? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.contains("="),
              !token.contains(";"),
              !token.contains(" "),
              !token.contains("\n"),
              token.count >= 40 || token.split(separator: ".").count >= 3
        else {
            return nil
        }
        return token
    }
}
