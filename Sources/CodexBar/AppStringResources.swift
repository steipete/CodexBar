import Foundation

enum AppStringResources {
    private static let supportedLocalizations = ["en", "zh-Hans", "zh-Hant"]

    static func localizedString(for key: String, table: String, language: AppLanguage) -> String {
        if let localized = self.localizedString(
            for: key,
            table: table,
            localization: language.localizationIdentifier)
        {
            return localized
        }
        if let english = self.localizedString(for: key, table: table, localization: "en") {
            return english
        }
        return key
    }

    private static func localizedString(for key: String, table: String, localization: String?) -> String? {
        guard let bundle = self.bundle(for: localization) else { return nil }
        let sentinel = "__codexbar_missing_translation__"
        let value = bundle.localizedString(forKey: key, value: sentinel, table: table)
        return value == sentinel ? nil : value
    }

    private static func bundle(for localization: String?) -> Bundle? {
        guard let localization else { return Bundle.module }
        guard self.supportedLocalizations.contains(localization),
              let bundleURL = Bundle.module.resourceURL?.appendingPathComponent("\(localization).lproj"),
              FileManager.default.fileExists(atPath: bundleURL.path)
        else {
            return nil
        }
        return Bundle(url: bundleURL)
    }
}
