import Foundation

public enum L10n {
    private static let appLanguageKey = "appLanguageCode"

    public static func tr(_ key: String, fallback: String) -> String {
        let bundle = self.localizedBundleOverride() ?? .module
        return NSLocalizedString(
            key,
            tableName: "Localizable",
            bundle: bundle,
            value: fallback,
            comment: "")
    }

    private static func localizedBundleOverride() -> Bundle? {
        guard let raw = UserDefaults.standard.string(forKey: Self.appLanguageKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return nil
        }
        if raw == "system" { return nil }

        let candidates = [
            raw,
            raw.lowercased(),
            raw.replacingOccurrences(of: "_", with: "-"),
            raw.replacingOccurrences(of: "_", with: "-").lowercased(),
        ]

        for candidate in candidates {
            if let path = Bundle.module.path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path)
            {
                return bundle
            }
        }
        return nil
    }
}
