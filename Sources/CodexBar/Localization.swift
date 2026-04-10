import Foundation

enum L10n {
    static func tr(_ key: String) -> String {
        NSLocalizedString(key, bundle: .module, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        let format = Self.tr(key)
        return String(format: format, locale: .current, arguments: arguments)
    }

    static func localizedDynamicValue(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let normalized = trimmed.lowercased()
        let localizedNormalized = Self.tr(normalized)
        if localizedNormalized != normalized {
            return localizedNormalized
        }

        let localizedExact = Self.tr(trimmed)
        return localizedExact == trimmed ? trimmed : localizedExact
    }
}
