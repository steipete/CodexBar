import Foundation

public struct DoubaoCookieOverride: Sendable {
    public let cookieHeader: String

    public init(cookieHeader: String) {
        self.cookieHeader = cookieHeader
    }
}

public enum DoubaoCookieHeader {
    private static let log = CodexBarLog.logger(LogCategories.doubaoCookie)
    private static let headerPatterns: [String] = [
        #"(?i)-H\s*'Cookie:\s*([^']+)'"#,
        #"(?i)-H\s*"Cookie:\s*([^"]+)""#,
        #"(?i)\bcookie:\s*'([^']+)'"#,
        #"(?i)\bcookie:\s*"([^"]+)""#,
        #"(?i)\bcookie:\s*([^\r\n]+)"#,
    ]

    public static func resolveCookieOverride(context: ProviderFetchContext) -> DoubaoCookieOverride? {
        if let settings = context.settings?.doubao, settings.cookieSource == .manual {
            if let manual = settings.manualCookieHeader, !manual.isEmpty {
                return self.override(from: manual)
            }
        }

        if let envToken = self.override(from: context.env["DOUBAO_MANUAL_COOKIE"]) {
            return envToken
        }

        return nil
    }

    public static func override(from raw: String?) -> DoubaoCookieOverride? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        if raw.contains("=") {
            return DoubaoCookieOverride(cookieHeader: raw)
        }

        if let cookieHeader = self.extractHeader(from: raw) {
            return DoubaoCookieOverride(cookieHeader: cookieHeader)
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
            else { continue }
            let captured = String(raw[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !captured.isEmpty { return captured }
        }
        return nil
    }
}
