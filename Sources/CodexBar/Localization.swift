import Foundation

enum CodexBarLocalizationOverride {
    @TaskLocal static var appLanguage: String?
}

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
    let language = CodexBarLocalizationOverride.appLanguage ?? appLanguageDefaults().string(forKey: "appLanguage") ?? ""
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

func L(_ key: String) -> String {
    let resourceBundle = codexBarLocalizationResourceBundle()
    return codexBarLocalizedString(key, bundle: localizedBundle(), resourceBundle: resourceBundle)
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), arguments: arguments)
}

func codexBarLocalizedString(_ key: String, bundle: Bundle, resourceBundle: Bundle) -> String {
    let value = bundle.localizedString(forKey: key, value: nil, table: nil)
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty, value != key {
        return value
    }

    guard bundle.bundleURL.lastPathComponent != "en.lproj",
          let englishBundle = lprojBundle(named: "en", in: resourceBundle)
    else {
        return trimmed.isEmpty ? key : value
    }

    let fallback = englishBundle.localizedString(forKey: key, value: nil, table: nil)
    return fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? key : fallback
}
