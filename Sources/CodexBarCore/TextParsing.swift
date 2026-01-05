import Foundation

public enum TextParsing {
    /// Removes ANSI escape sequences so regex parsing works on colored terminal output.
    public static func stripANSICodes(_ text: String) -> String {
        // CSI sequences: ESC [ ... ending in 0x40–0x7E
        let pattern = #"\u001B\[[0-?]*[ -/]*[@-~]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    /// Parses a number string with automatic locale detection.
    ///
    /// Handles both US format (1,234.56) and European format (1.234,56) by detecting
    /// which separator is the decimal point based on position and digit count.
    public static func parseLocalizedNumber(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let hasDot = trimmed.contains(".")
        let hasComma = trimmed.contains(",")

        if hasDot && hasComma {
            // Both separators present: the last one is the decimal separator
            guard let lastDot = trimmed.lastIndex(of: "."),
                  let lastComma = trimmed.lastIndex(of: ",")
            else {
                return nil
            }

            if lastDot > lastComma {
                // US format: 1,234.56
                let cleaned = trimmed.replacingOccurrences(of: ",", with: "")
                return Double(cleaned)
            } else {
                // European format: 1.234,56
                let cleaned = trimmed
                    .replacingOccurrences(of: ".", with: "")
                    .replacingOccurrences(of: ",", with: ".")
                return Double(cleaned)
            }
        } else if hasComma {
            // Only comma - check digits after comma to determine if decimal or thousands
            if let commaIndex = trimmed.lastIndex(of: ",") {
                let afterComma = trimmed[trimmed.index(after: commaIndex)...]
                let digitCount = afterComma.filter(\.isNumber).count

                if digitCount <= 2 {
                    // European decimal: "20,00" or "20,5"
                    let cleaned = trimmed.replacingOccurrences(of: ",", with: ".")
                    return Double(cleaned)
                } else {
                    // US thousands: "1,000" or "1,234,567"
                    let cleaned = trimmed.replacingOccurrences(of: ",", with: "")
                    return Double(cleaned)
                }
            }
            return nil
        } else {
            // No comma (may have dot or no separator) - parse directly
            return Double(trimmed)
        }
    }

    public static func firstNumber(pattern: String, text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return parseLocalizedNumber(String(text[r]))
    }

    public static func firstInt(pattern: String, text: String) -> Int? {
        guard let v = firstNumber(pattern: pattern, text: text) else { return nil }
        return Int(v)
    }

    public static func firstLine(matching pattern: String, text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let r = Range(match.range(at: 0), in: text) else { return nil }
        return String(text[r])
    }

    public static func percentLeft(fromLine line: String) -> Int? {
        guard let pct = firstInt(pattern: #"([0-9]{1,3})%\s+left"#, text: line) else { return nil }
        return pct
    }

    public static func resetString(fromLine line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"resets?\s+(.+)"#, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: line)
        else {
            return nil
        }
        // Return the tail text only (drop the "resets" prefix).
        return String(line[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
