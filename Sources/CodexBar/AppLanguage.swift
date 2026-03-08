import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case en
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case ja
    case ko
    case fr
    case de
    case es

    var id: String {
        self.rawValue
    }

    var displayName: String {
        switch self {
        case .system: String(localized: "System Default")
        case .en: "English"
        case .zhHans: "简体中文"
        case .zhHant: "繁體中文"
        case .ja: "日本語"
        case .ko: "한국어"
        case .fr: "Français"
        case .de: "Deutsch"
        case .es: "Español"
        }
    }

    var localeIdentifier: String? {
        switch self {
        case .system: nil
        default: self.rawValue
        }
    }

    static func applyLanguage(_ language: AppLanguage) {
        if let identifier = language.localeIdentifier {
            UserDefaults.standard.set([identifier], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
    }
}
