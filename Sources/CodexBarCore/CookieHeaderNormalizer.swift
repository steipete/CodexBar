import Foundation

public enum CookieHeaderNormalizer {
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

    public static func normalize(_ raw: String?) -> String? {
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

    public static func pairs(from raw: String) -> [(name: String, value: String)] {
        guard let normalized = self.normalize(raw) else { return [] }
        var results: [(name: String, value: String)] = []
        results.reserveCapacity(6)

        for part in normalized.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let equalsIndex = trimmed.firstIndex(of: "=")
            else {
                continue
            }
            let name = trimmed[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = trimmed[trimmed.index(after: equalsIndex)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            results.append((name: String(name), value: String(value)))
        }

        return results
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
            let captured = raw[captureRange].trimmingCharacters(in: .whitespacesAndNewlines)
            if !captured.isEmpty { return String(captured) }
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
}
