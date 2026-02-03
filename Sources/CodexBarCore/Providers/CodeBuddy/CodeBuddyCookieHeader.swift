import Foundation

public struct CodeBuddyCookieOverride: Sendable {
    public let cookieHeader: String
    public let enterpriseID: String?

    public init(cookieHeader: String, enterpriseID: String? = nil) {
        self.cookieHeader = cookieHeader
        self.enterpriseID = enterpriseID
    }
}

public enum CodeBuddyCookieHeader {
    private static let log = CodexBarLog.logger(LogCategories.codeBuddyCookie)
    private static let headerPatterns: [String] = [
        #"(?i)session=([A-Za-z0-9._\-+=/|]+)"#,
        #"(?i)-H\s*'Cookie:\s*([^']+)'"#,
        #"(?i)-H\s*"Cookie:\s*([^"]+)""#,
        #"(?i)\bcookie:\s*'([^']+)'"#,
        #"(?i)\bcookie:\s*"([^"]+)""#,
        #"(?i)\bcookie:\s*([^\r\n]+)"#,
    ]

    public static func resolveCookieOverride(context: ProviderFetchContext) -> CodeBuddyCookieOverride? {
        if let settings = context.settings?.codebuddy, settings.cookieSource == .manual {
            if let manual = settings.manualCookieHeader, !manual.isEmpty {
                return self.override(from: manual, enterpriseID: settings.enterpriseID)
            }
        }

        if let envCookie = self.override(from: context.env["CODEBUDDY_COOKIE"]) {
            return envCookie
        }

        return nil
    }

    public static func override(from raw: String?, enterpriseID: String? = nil) -> CodeBuddyCookieOverride? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        // Try to extract session cookie from the raw input
        if let sessionValue = self.extractSessionCookie(from: raw) {
            // If raw already looks like a cookie header, use it directly
            if raw.contains("session=") {
                return CodeBuddyCookieOverride(cookieHeader: raw, enterpriseID: enterpriseID)
            }
            // Otherwise construct a minimal header
            return CodeBuddyCookieOverride(cookieHeader: "session=\(sessionValue)", enterpriseID: enterpriseID)
        }

        // Try extracting from curl command or header format
        if let cookieHeader = self.extractHeader(from: raw) {
            return CodeBuddyCookieOverride(cookieHeader: cookieHeader, enterpriseID: enterpriseID)
        }

        return nil
    }

    private static func extractSessionCookie(from raw: String) -> String? {
        let patterns = [
            #"(?i)session=([A-Za-z0-9._\-+=/|]+)"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            guard let match = regex.firstMatch(in: raw, options: [], range: range),
                  match.numberOfRanges >= 2,
                  let captureRange = Range(match.range(at: 1), in: raw)
            else {
                continue
            }
            let token = String(raw[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { return token }
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

    /// Extract enterprise ID from the x-enterprise-id header in a curl command
    public static func extractEnterpriseID(from raw: String) -> String? {
        let patterns = [
            #"(?i)x-enterprise-id:\s*([A-Za-z0-9]+)"#,
            #"(?i)-H\s*'x-enterprise-id:\s*([A-Za-z0-9]+)'"#,
            #"(?i)-H\s*"x-enterprise-id:\s*([A-Za-z0-9]+)""#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            guard let match = regex.firstMatch(in: raw, options: [], range: range),
                  match.numberOfRanges >= 2,
                  let captureRange = Range(match.range(at: 1), in: raw)
            else {
                continue
            }
            let id = String(raw[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty { return id }
        }
        return nil
    }
}
