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

    public static func redact(_ text: String) -> String {
        var output = text
        // Email is broad and safe first
        output = self.replace(self.emailRegex, in: output, with: "<redacted-email>")
        // MiniMax tokens before broader rules catch them
        output = self.replace(self.minimaxCodingPlanTokenRegex, in: output, with: "<redacted-minimax-token>")
        output = self.replace(self.minimaxApiTokenRegex, in: output, with: "<redacted-minimax-token>")
        // Bearer catches "bearer <token>" before authorization wraps it
        output = self.replace(self.bearerRegex, in: output, with: "Bearer <redacted>")
        // Authorization catches the rest (already-redacted content)
        output = self.replace(self.cookieHeaderRegex, in: output, with: "$1<redacted>")
        output = self.replace(self.authorizationRegex, in: output, with: "$1<redacted>")
        return output
    }

    private static func makeRegex(pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        (try? NSRegularExpression(pattern: pattern, options: options)) ?? self.fallbackRegex
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
