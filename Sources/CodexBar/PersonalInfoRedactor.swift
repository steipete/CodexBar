import Foundation

enum PersonalInfoRedactor {
    /// A source-issued slot is safe to show when arbitrary account labels are hidden.
    struct AccountOrdinal: Equatable {
        private let number: Int

        init?(_ number: Int) {
            guard number > 0 else { return nil }
            self.number = number
        }

        var label: String {
            String(format: L("Account %@"), String(self.number))
        }
    }

    static let emailPlaceholder = ""

    private static let emailRegex: NSRegularExpression? = {
        let pattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    static func redactEmail(_ email: String?, isEnabled: Bool) -> String {
        guard let email, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        guard isEnabled else { return email }
        return Self.emailPlaceholder
    }

    static func redactAccountLabel(
        _ label: String?,
        isEnabled: Bool,
        ordinal: AccountOrdinal? = nil) -> String
    {
        if isEnabled, let ordinal { return ordinal.label }
        return Self.redactEmail(label, isEnabled: isEnabled)
    }

    static func redactEmails(in text: String?, isEnabled: Bool) -> String? {
        guard let text else { return nil }
        guard isEnabled else { return text }
        guard let regex = Self.emailRegex else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard regex.firstMatch(in: text, options: [], range: range) != nil else { return text }
        let redacted = regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: Self.emailPlaceholder)
        return redacted
            .replacingOccurrences(of: #"\s+([:.,;])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
