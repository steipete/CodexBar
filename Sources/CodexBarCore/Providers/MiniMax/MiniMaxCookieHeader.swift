import Foundation

public struct MiniMaxCookieOverride: Sendable {
    public let cookieHeader: String
    public let authorizationToken: String?
    public let groupID: String?

    public init(cookieHeader: String, authorizationToken: String?, groupID: String?) {
        self.cookieHeader = cookieHeader
        self.authorizationToken = authorizationToken
        self.groupID = groupID
    }
}

public enum MiniMaxCookieHeader {
    private static let headerPatterns: [String] = [
        #"(?i)-H\s*'Cookie:\s*([^']+)'"#,
        #"(?i)-H\s*\"Cookie:\s*([^\"]+)\""#,
        #"(?i)\bcookie:\s*'([^']+)'"#,
        #"(?i)\bcookie:\s*\"([^\"]+)\""#,
        #"(?i)\bcookie:\s*([^\r\n]+)"#,
        #"(?i)(?:--cookie|-b)\s*'([^']+)'"#,
        #"(?i)(?:--cookie|-b)\s*\"([^\"]+)\""#,
        #"(?i)(?:--cookie|-b)\s*([^\s]+)"#,
    ]
    private static let authorizationPattern = #"(?i)\bauthorization:\s*bearer\s+([A-Za-z0-9._\-+=/]+)"#
    private static let groupIDPattern = #"(?i)\bgroup[_]?id=([0-9]{4,})"#

    public static func override(from raw: String?) -> MiniMaxCookieOverride? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        guard let cookie = self.normalized(from: raw) else { return nil }
        let authorizationToken = self.extractFirst(pattern: self.authorizationPattern, text: raw)
        let groupID = self.extractFirst(pattern: self.groupIDPattern, text: raw)
        return MiniMaxCookieOverride(
            cookieHeader: cookie,
            authorizationToken: authorizationToken,
            groupID: groupID)
    }

    public static func normalized(from raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if let extracted = self.extractHeader(from: value) {
            value = extracted
        }

        value = self.stripCookiePrefix(value)
        value = self.stripWrappingQuotes(value)
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)

        return value.isEmpty ? nil : value
    }

    private static func extractHeader(from raw: String) -> String? {
        for pattern in self.headerPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            guard let match = regex.firstMatch(in: raw, options: [], range: range),
                  match.numberOfRanges >= 2,
                  let captureRange = Range(match.range(at: 1), in: raw)
            else {
                continue
            }
            let captured = String(raw[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !captured.isEmpty { return captured }
        }
        return nil
    }

    private static func stripCookiePrefix(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("cookie:") else { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: "cookie:".count)
        return String(trimmed[idx...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripWrappingQuotes(_ raw: String) -> String {
        guard raw.count >= 2 else { return raw }
        if (raw.hasPrefix("\"") && raw.hasSuffix("\"")) ||
            (raw.hasPrefix("'") && raw.hasSuffix("'"))
        {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }

    private static func extractFirst(pattern: String, text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let captureRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        let value = text[captureRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value)
    }
}
