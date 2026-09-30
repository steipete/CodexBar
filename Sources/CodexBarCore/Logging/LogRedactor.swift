import Foundation

public enum LogRedactor {
    private static let fallbackRegex: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: "$^", options: [])
        } catch {
            fatalError("Failed to build fallback regex: \(error)")
        }
    }()

    private static let emailRegex = Self.makeRegex(
        pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
        options: [.caseInsensitive])
    private static let cookieHeaderRegex = Self.makeRegex(
        pattern: #"(?i)(cookie\s*:\s*)([^\r\n]+)"#)
    private static let authorizationRegex = Self.makeRegex(
        pattern: #"(?i)(authorization\s*:\s*)([^\r\n]+)"#)
    private static let bearerRegex = Self.makeRegex(
        pattern: #"(?i)\bbearer\s+[a-z0-9._\-]+=*\b"#)
    private static let minimaxCodingPlanTokenRegex = Self.makeRegex(
        pattern: #"sk-cp-[^\s"'`;,)>\]]+"#)
    private static let minimaxApiTokenRegex = Self.makeRegex(
        pattern: #"sk-api-[^\s"'`;,)>\]]+"#)
    private static let genericSkTokenRegex = Self.makeRegex(
        pattern: #"\bsk-[a-z0-9._\-]{20,}"#,
        options: [.caseInsensitive])
    private static let knownProviderTokenRegex = Self.makeRegex(
        pattern: #"\b(?:xai-[a-zA-Z0-9._\-]{20,}|gsk_[a-zA-Z0-9._\-]{20,}|pplx-[a-zA-Z0-9._\-]{20,})"#)
    private static let scopedPlatformTokenRegex = Self.makeRegex(
        pattern: #"\b(?:hf_[a-zA-Z0-9._\-]{20,}|AIza[a-zA-Z0-9._\-]{20,})"#)
    private static let jwtRegex = Self.makeRegex(
        pattern: #"\beyJ[a-zA-Z0-9_\-]+\.[a-zA-Z0-9_\-]+\.[a-zA-Z0-9_\-]+"#)
    private static let apiKeyLabelRegex = Self.makeRegex(
        pattern: #"(?i)((?:x-)?api[-_\s]?key\s*[:=]\s*)([^\s,;&\r\n]+)"#)
    private static let querySecretRegex = Self.makeRegex(
        pattern: #"(?i)([?&](?:token|key|api[-_]?key|access_token|sig)=)([^&\s"']+)"#)

    public static func redact(_ text: String) -> String {
        guard self.mayContainSensitiveValue(text) else { return text }

        var output = text
        // Email is broad and safe first
        output = self.replace(self.emailRegex, in: output, with: "<redacted-email>")
        // MiniMax tokens before broader rules catch them
        output = self.replace(self.minimaxCodingPlanTokenRegex, in: output, with: "<redacted-minimax-token>")
        output = self.replace(self.minimaxApiTokenRegex, in: output, with: "<redacted-minimax-token>")
        // Bearer catches "bearer <token>" before authorization wraps it
        output = self.replace(self.bearerRegex, in: output, with: "Bearer <redacted>")
        // Bare provider token shapes (OpenAI sk-*, xAI, Groq, Perplexity, HF, Google)
        output = self.replace(self.genericSkTokenRegex, in: output, with: "<redacted-token>")
        output = self.replace(self.knownProviderTokenRegex, in: output, with: "<redacted-token>")
        output = self.replace(self.scopedPlatformTokenRegex, in: output, with: "<redacted-token>")
        output = self.replace(self.jwtRegex, in: output, with: "<redacted-jwt>")
        // Authorization catches the rest (already-redacted content)
        output = self.replace(self.cookieHeaderRegex, in: output, with: "$1<redacted>")
        output = self.replace(self.authorizationRegex, in: output, with: "$1<redacted>")
        output = self.replace(self.apiKeyLabelRegex, in: output, with: "$1<redacted>")
        output = self.replace(self.querySecretRegex, in: output, with: "$1<redacted>")
        return output
    }

    private static func mayContainSensitiveValue(_ text: String) -> Bool {
        if text.range(of: "@") != nil { return true }
        if text.range(of: "sk-", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "xai-", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "gsk_", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "pplx-", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "hf_", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "AIza") != nil { return true }
        if text.range(of: "eyJ") != nil { return true }
        if text.range(of: "bearer", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "cookie", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "authorization", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "api-key", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "api key", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "api_key", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "apikey", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "token=", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "key=", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "sig=", options: [.caseInsensitive]) != nil { return true }
        return false
    }

    private static func makeRegex(pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        (try? NSRegularExpression(pattern: pattern, options: options)) ?? self.fallbackRegex
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
