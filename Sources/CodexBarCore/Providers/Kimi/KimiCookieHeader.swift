import Foundation

public struct KimiCookieOverride: Sendable {
    public let token: String

    public init(token: String) {
        self.token = token
    }
}

public enum KimiCookieHeader {
    private static let log = CodexBarLog.logger("kimi-cookie")
    private static let headerPatterns: [String] = [
        #"(?i)kimi-auth=([A-Za-z0-9._\-+=/]+)"#,
        #"(?i)-H\s*'Cookie:\s*([^']+)'"#,
        #"(?i)-H\s*"Cookie:\s*([^"]+)""#,
        #"(?i)\bcookie:\s*'([^']+)'"#,
        #"(?i)\bcookie:\s*"([^"]+)""#,
        #"(?i)\bcookie:\s*([^\r\n]+)"#,
    ]

    public static func resolveCookieOverride(context: ProviderFetchContext) -> KimiCookieOverride? {
        if let settings = context.settings?.kimi, settings.cookieSource == .manual {
            if let manual = settings.manualCookieHeader, !manual.isEmpty {
                return self.override(from: manual)
            }
        }

        if let envToken = self.override(from: context.env["KIMI_MANUAL_COOKIE"]) {
            return envToken
        }
        if let envToken = self.override(from: context.env["KIMI_AUTH_TOKEN"]) {
            return envToken
        }

        return nil
    }

    public static func override(from raw: String?) -> KimiCookieOverride? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        if let token = self.extractKIMAuthToken(from: raw) {
            return KimiCookieOverride(token: token)
        }

        if let cookieHeader = self.extractHeader(from: raw),
           let token = self.extractKIMAuthToken(from: cookieHeader)
        {
            return KimiCookieOverride(token: token)
        }

        if raw.hasPrefix("eyJ"), raw.split(separator: ".").count == 3 {
            return KimiCookieOverride(token: raw)
        }

        return nil
    }

    private static func extractKIMAuthToken(from raw: String) -> String? {
        let patterns = [
            #"(?i)kimi-auth=([A-Za-z0-9._\-+=/]+)"#,
            #"(?i)kimi-auth:\s*([A-Za-z0-9._\-+=/]+)"#,
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
}
