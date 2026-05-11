import Foundation

private func appLanguageDefaults() -> UserDefaults {
    if Bundle.main.bundleIdentifier != nil {
        return .standard
    }
    // Fallback for running outside a .app bundle (swift run / debug builds)
    return UserDefaults(suiteName: "CodexBar") ?? .standard
}

func codexBarLocalizationResourceBundle(
    mainBundle: Bundle = .main,
    bundleName: String = "CodexBar_CodexBar") -> Bundle
{
    guard mainBundle.bundleURL.pathExtension == "app" else {
        return Bundle.module
    }

    if let url = mainBundle.url(forResource: bundleName, withExtension: "bundle"),
       let bundle = Bundle(url: url)
    {
        return bundle
    }

    if let resourceURL = mainBundle.resourceURL?.absoluteURL,
       let bundle = Bundle(url: resourceURL.appendingPathComponent("\(bundleName).bundle"))
    {
        return bundle
    }

    return mainBundle
}

private func localizedBundle() -> Bundle {
    let resourceBundle = codexBarLocalizationResourceBundle()
    let language = appLanguageDefaults().string(forKey: "appLanguage") ?? ""
    if !language.isEmpty {
        if let path = resourceBundle.path(forResource: language, ofType: "lproj"),
           let bundle = Bundle(path: path)
        {
            return bundle
        }
    } else {
        // System mode: follow macOS language preferences
        if let preferred = resourceBundle.preferredLocalizations.first,
           let path = resourceBundle.path(forResource: preferred, ofType: "lproj"),
           let bundle = Bundle(path: path)
        {
            return bundle
        }
    }
    // Fallback to en.lproj
    if let path = resourceBundle.path(forResource: "en", ofType: "lproj"),
       let bundle = Bundle(path: path)
    {
        return bundle
    }
    return resourceBundle
}

func L(_ key: String) -> String {
    localizedBundle().localizedString(forKey: key, value: nil, table: nil)
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: localizedBundle().localizedString(forKey: key, value: nil, table: nil), arguments: arguments)
}
