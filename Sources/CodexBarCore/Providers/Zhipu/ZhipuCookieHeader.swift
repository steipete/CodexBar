import Foundation

public struct ZhipuCookieOverride: Sendable {
    public let cookieHeader: String

    public init(cookieHeader: String) {
        self.cookieHeader = cookieHeader
    }
}

public enum ZhipuCookieHeader {
    private static let log = CodexBarLog.logger(LogCategories.zhipuCookie)
    private static let headerPatterns: [String] = [
        #"(?i)-H\s*'Cookie:\s*([^']+)'"#,
        #"(?i)-H\s*"Cookie:\s*([^"]+)""#,
        #"(?i)\bcookie:\s*'([^']+)'"#,
        #"(?i)\bcookie:\s*"([^"]+)""#,
        #"(?i)\bcookie:\s*([^\r\n]+)"#,
    ]

    public static func resolveCookieOverride(context: ProviderFetchContext) -> ZhipuCookieOverride? {
        if let settings = context.settings?.zhipu, settings.cookieSource == .manual {
            if let manual = settings.manualCookieHeader, !manual.isEmpty {
                return self.override(from: manual)
            }
        }

        if let envToken = self.override(from: context.env["ZHIPU_MANUAL_COOKIE"]) {
            return envToken
        }

        return nil
    }

    public static func override(from raw: String?) -> ZhipuCookieOverride? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        // If it looks like a Cookie header value (contains = and ;)
        if raw.contains("=") {
            return ZhipuCookieOverride(cookieHeader: raw)
        }

        // Try extracting from curl-style or other patterns
        if let cookieHeader = self.extractHeader(from: raw) {
            return ZhipuCookieOverride(cookieHeader: cookieHeader)
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
