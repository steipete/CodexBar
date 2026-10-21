import Foundation

enum MenuInlineCodeText {
    private static let spans = try? NSRegularExpression(pattern: #"(?<!`)`([^`]+)`(?!`)"#)

    /// Only paired single backticks carry formatting; all other text stays literal.
    static func attributed(_ text: String) -> AttributedString {
        guard let spans else { return AttributedString(text) }
        var result = AttributedString()
        var cursor = text.startIndex
        for match in spans.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text),
                  let codeRange = Range(match.range(at: 1), in: text)
            else { continue }
            result.append(AttributedString(String(text[cursor..<range.lowerBound])))
            var code = AttributedString(String(text[codeRange]))
            code.inlinePresentationIntent = .code
            result.append(code)
            cursor = range.upperBound
        }
        result.append(AttributedString(String(text[cursor...])))
        return result
    }
}
