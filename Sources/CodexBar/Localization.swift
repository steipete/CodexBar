import Foundation

private func appLanguageDefaults() -> UserDefaults {
    if Bundle.main.bundleIdentifier != nil {
        return .standard
    }
    // Fallback for running outside a .app bundle (swift run / debug builds)
    return UserDefaults(suiteName: "CodexBar") ?? .standard
}

private func localizedBundle() -> Bundle {
    let language = appLanguageDefaults().string(forKey: "appLanguage") ?? ""
    if !language.isEmpty {
        if let path = Bundle.module.path(forResource: language, ofType: "lproj"),
           let bundle = Bundle(path: path)
        {
            return bundle
        }
    } else {
        // System mode: follow macOS language preferences
        if let preferred = Bundle.module.preferredLocalizations.first,
           let path = Bundle.module.path(forResource: preferred, ofType: "lproj"),
           let bundle = Bundle(path: path)
        {
            return bundle
        }
    }
    // Fallback to en.lproj
    if let path = Bundle.module.path(forResource: "en", ofType: "lproj"),
       let bundle = Bundle(path: path)
    {
        return bundle
    }
    return Bundle.module
}

func L(_ key: String) -> String {
    localizedBundle().localizedString(forKey: key, value: nil, table: nil)
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: localizedBundle().localizedString(forKey: key, value: nil, table: nil), arguments: arguments)
}
