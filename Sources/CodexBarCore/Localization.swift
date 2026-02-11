import Foundation

public enum L10n {
    private static let appLanguageKey = "appLanguageCode"
    private static let appleLanguagesKey = "AppleLanguages"

    public static func tr(_ key: String, fallback: String) -> String {
        let bundle = self.localizedBundle()
        return NSLocalizedString(
            key,
            tableName: "Localizable",
            bundle: bundle,
            value: fallback,
            comment: "")
    }

    private static func localizedBundle() -> Bundle {
        let selected = UserDefaults.standard.string(forKey: Self.appLanguageKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let usesSystemLanguage = selected.isEmpty || selected == "system"

        let preferences = usesSystemLanguage
            ? self.systemLanguagePreferences()
            : self.languageCandidates(for: selected)

        guard let bundle = self.bundle(matching: preferences) else { return .module }
        return bundle
    }

    private static func systemLanguagePreferences() -> [String] {
        if let explicit = UserDefaults.standard.array(forKey: Self.appleLanguagesKey) as? [String],
           !explicit.isEmpty
        {
            return explicit
        }
        let preferred = Locale.preferredLanguages
        if !preferred.isEmpty { return preferred }
        return [Locale.current.identifier]
    }

    private static func languageCandidates(for raw: String) -> [String] {
        let normalized = raw.replacingOccurrences(of: "_", with: "-")
        var candidates: [String] = [raw, raw.lowercased(), normalized, normalized.lowercased()]
        if normalized.contains("-") {
            let parts = normalized.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
            if let base = parts.first {
                candidates.append(String(base))
                candidates.append(String(base).lowercased())
            }
        }

        var seen: Set<String> = []
        return candidates.filter { seen.insert($0).inserted && !$0.isEmpty }
    }

    private static func bundle(matching preferences: [String]) -> Bundle? {
        let available = Bundle.module.localizations.filter { $0 != "Base" }
        guard !available.isEmpty else { return nil }

        let preferred = Bundle.preferredLocalizations(from: available, forPreferences: preferences)
        for language in preferred {
            if let path = Bundle.module.path(forResource: language, ofType: "lproj"),
               let bundle = Bundle(path: path)
            {
                return bundle
            }
        }

        for language in preferences {
            for candidate in self.languageCandidates(for: language) {
                if let path = Bundle.module.path(forResource: candidate, ofType: "lproj"),
                   let bundle = Bundle(path: path)
                {
                    return bundle
                }
            }
        }
        return nil
    }
}
