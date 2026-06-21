import Foundation

public struct LongCatCookieOverride: Sendable {
    /// Full `Cookie:` header value (e.g. `name=value; name2=value2`).
    public let cookieHeader: String

    public init(cookieHeader: String) {
        self.cookieHeader = cookieHeader
    }
}

public enum LongCatCookieHeader {
    private static let log = CodexBarLog.logger(LogCategories.longcatCookie)
    private static let headerPatterns: [String] = [
        #"(?i)-H\s*'Cookie:\s*([^']+)'"#,
        #"(?i)-H\s*"Cookie:\s*([^"]+)""#,
        #"(?i)\bcookie:\s*'([^']+)'"#,
        #"(?i)\bcookie:\s*"([^"]+)""#,
        #"(?i)\bcookie:\s*([^\r\n]+)"#,
    ]

    public static func resolveCookieOverride(context: ProviderFetchContext) -> LongCatCookieOverride? {
        if let settings = context.settings?.longcat, settings.cookieSource == .manual {
            if let manual = settings.manualCookieHeader, !manual.isEmpty {
                return self.override(from: manual)
            }
        }

        if let envHeader = self.override(from: context.env["LONGCAT_MANUAL_COOKIE"]) {
            return envHeader
        }

        return nil
    }

    public static func override(from raw: String?) -> LongCatCookieOverride? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        if let header = self.extractHeader(from: raw) {
            return LongCatCookieOverride(cookieHeader: header)
        }

        // A bare `name=value; ...` string is itself a usable cookie header.
        if raw.contains("=") {
            return LongCatCookieOverride(cookieHeader: raw)
        }

        return nil
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
}
