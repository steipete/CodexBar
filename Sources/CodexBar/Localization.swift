import Foundation

private func appLanguageDefaults() -> UserDefaults {
    if Bundle.main.bundleIdentifier != nil {
        return .standard
    }
    if UserDefaults.standard.object(forKey: "appLanguage") != nil {
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
        if let bundle = lprojBundle(named: language, in: resourceBundle) {
            return bundle
        }
    } else {
        // System mode: follow macOS language preferences
        if let preferred = resourceBundle.preferredLocalizations.first,
           let bundle = lprojBundle(named: preferred, in: resourceBundle)
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

func codexBarLocalizationLocale() -> Locale {
    let language = appLanguageDefaults().string(forKey: "appLanguage") ?? ""
    if !language.isEmpty {
        return Locale(identifier: language)
    }
    return .autoupdatingCurrent
}

private func lprojBundle(named language: String, in resourceBundle: Bundle) -> Bundle? {
    let candidates = [language, language.lowercased()]
    for candidate in candidates where !candidate.isEmpty {
        if let path = resourceBundle.path(forResource: candidate, ofType: "lproj"),
           let bundle = Bundle(path: path)
        {
            return bundle
        }
    }
    return nil
}

private func localizedString(for key: String) -> String {
    let bundle = localizedBundle()
    let value = bundle.localizedString(forKey: key, value: nil, table: nil)
    guard value == key else { return value }

    let resourceBundle = codexBarLocalizationResourceBundle()
    guard bundle.bundleURL.lastPathComponent != "en.lproj",
          let englishBundle = lprojBundle(named: "en", in: resourceBundle)
    else {
        return value
    }

    let fallback = englishBundle.localizedString(forKey: key, value: nil, table: nil)
    return fallback == key ? value : fallback
}

func L(_ key: String) -> String {
    localizedString(for: key)
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: localizedString(for: key), arguments: arguments)
}
