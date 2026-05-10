import Foundation

public enum CodexPlanFormatting {
    private static let exactDisplayNames: [String: String] = [
        "pro": "Pro 20x",
        "prolite": "Pro 5x",
        "pro_lite": "Pro 5x",
        "pro-lite": "Pro 5x",
        "pro lite": "Pro 5x",
    ]

    private static let uppercaseWords: Set<String> = [
        "cbp",
        "k12",
    ]

    public static func displayName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        let lower = raw.lowercased()
        if let exact = Self.exactDisplayNames[lower] {
            return exact
        }

        let cleaned = UsageFormatter.cleanPlanName(raw)
        let candidate = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return raw }

        if let exact = Self.exactDisplayNames[candidate.lowercased()] {
            return exact
        }

        let components = candidate
            .split(whereSeparator: { $0 == "_" || $0 == "-" || $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !components.isEmpty else { return candidate }

        let formatted = components.map(Self.wordDisplayName).joined(separator: " ")
        return formatted.isEmpty ? candidate : formatted
    }

    private static func wordDisplayName(_ raw: String) -> String {
        let lower = raw.lowercased()
        if Self.uppercaseWords.contains(lower) {
            return lower.uppercased()
        }
        if raw == raw.uppercased(), raw.contains(where: \.isLetter) {
            return raw
        }
        if let first = raw.first, first.isLowercase {
            return raw.prefix(1).uppercased() + raw.dropFirst()
        }
        return raw
    }
}
