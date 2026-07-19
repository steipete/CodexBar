import CodexBarCore
import Foundation

enum CodexBarLocalizationOverride {
    @TaskLocal static var appLanguage: String?
}

enum AppLanguagePreferenceMigration {
    private static let appleLanguagesKey = "AppleLanguages"

    static func clearLegacyOverrideIfOwned(
        storedAppLanguage: String,
        defaults: UserDefaults = .standard)
    {
        let language = storedAppLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !language.isEmpty,
              defaults.stringArray(forKey: self.appleLanguagesKey) == [language]
        else { return }

        defaults.removeObject(forKey: self.appleLanguagesKey)
    }
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

private let isRunningTestsProcessAtStartup: Bool = {
    let env = ProcessInfo.processInfo.environment
    if env["XCTestConfigurationFilePath"] != nil {
        return true
    }
    if env["TESTING_LIBRARY_VERSION"] != nil {
        return true
    }
    if env["SWIFT_TESTING"] != nil {
        return true
    }
    return NSClassFromString("XCTestCase") != nil
}()

private func isRunningTestsProcess() -> Bool {
    isRunningTestsProcessAtStartup
}

private func resolvedAppLanguage() -> String {
    if let override = CodexBarLocalizationOverride.appLanguage {
        return override
    }
    if isRunningTestsProcess() {
        return "en"
    }
    return appLanguageDefaults().string(forKey: "appLanguage") ?? ""
}

func codexBarLocalizationSignature() -> String {
    resolvedAppLanguage()
}

/// Resolving the `.lproj`/resource bundles repeats `Bundle(url:)`/`Bundle(path:)` filesystem lookups,
/// which are surprisingly hot: every `L(…)` and `codexBarLocalizationSignature()` call runs them, and
/// menu row bodies (`MetricRow`, `ProviderCostContent`, `UsageMenuCardView.Model`) re-evaluate them on
/// every closed-menu rebuild tick on the main thread (#1347). The resolved bundles never change unless
/// the language changes, so cache them. A single lock with compute-happening-outside-the-lock keeps the
/// disk work off the critical section and avoids re-entrant deadlock when the localized-bundle compute
/// closure calls back into the resource-bundle accessor.
private enum LocalizationBundleCache {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var resourceBundle: Bundle?
    private nonisolated(unsafe) static var localizedBundlesByLanguage: [String: Bundle] = [:]

    static func defaultResourceBundle(_ compute: () -> Bundle) -> Bundle {
        self.lock.lock()
        if let resourceBundle {
            self.lock.unlock()
            return resourceBundle
        }
        self.lock.unlock()
        let computed = compute()
        self.lock.lock()
        resourceBundle = computed
        self.lock.unlock()
        return computed
    }

    static func localizedBundle(forLanguage language: String, _ compute: () -> Bundle) -> Bundle {
        self.lock.lock()
        if let cachedLocalizedBundle = self.localizedBundlesByLanguage[language] {
            self.lock.unlock()
            return cachedLocalizedBundle
        }
        self.lock.unlock()
        let computed = compute()
        self.lock.lock()
        self.localizedBundlesByLanguage[language] = computed
        self.lock.unlock()
        return computed
    }

    static func reset() {
        self.lock.lock()
        self.resourceBundle = nil
        self.localizedBundlesByLanguage = [:]
        self.lock.unlock()
    }
}

func codexBarLocalizationResourceBundle(
    mainBundle: Bundle = .main,
    bundleName: String = "CodexBar_CodexBar") -> Bundle
{
    // Only the default (process `.main`) resolution is cached: it is constant for the lifetime of the
    // process. Custom arguments (tests) keep resolving directly so they stay isolated from the cache.
    guard mainBundle === Bundle.main, bundleName == "CodexBar_CodexBar" else {
        return resolveLocalizationResourceBundle(mainBundle: mainBundle, bundleName: bundleName)
    }
    return LocalizationBundleCache.defaultResourceBundle {
        resolveLocalizationResourceBundle(mainBundle: mainBundle, bundleName: bundleName)
    }
}

private func resolveLocalizationResourceBundle(mainBundle: Bundle, bundleName: String) -> Bundle {
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
    // Keyed on the resolved language so a language switch (settings change or test override) transparently
    // re-resolves; otherwise the cached bundle is returned without touching the filesystem.
    let language = resolvedAppLanguage()
    return localizedBundle(forLanguage: language)
}

private func localizedBundle(forLanguage language: String) -> Bundle {
    LocalizationBundleCache.localizedBundle(forLanguage: language) {
        resolveLocalizedBundle(forLanguage: language)
    }
}

private func resolveLocalizedBundle(forLanguage language: String) -> Bundle {
    let resourceBundle = codexBarLocalizationResourceBundle()
    if !language.isEmpty {
        if let bundle = lprojBundle(named: language, in: resourceBundle) {
            return bundle
        }
    } else {
        // System mode: follow macOS language preferences
        let localizations = resourceBundle.localizations.filter { $0 != "Base" }
        let preferred = Bundle.preferredLocalizations(
            from: localizations,
            forPreferences: Locale.preferredLanguages).first
        if let preferred,
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

func L(_ key: String, language: String) -> String {
    let resourceBundle = codexBarLocalizationResourceBundle()
    let bundle = localizedBundle(forLanguage: language)
    return codexBarLocalizedString(key, bundle: bundle, resourceBundle: resourceBundle)
}

func codexBarLocalizedLocale() -> Locale {
    let language = resolvedAppLanguage()
    guard !language.isEmpty else { return .current }
    let normalized = language.lowercased()
    if normalized == "ar" || normalized.hasPrefix("ar-") {
        return Locale(identifier: "\(language)@numbers=arab")
    }
    switch normalized {
    case "zh-hans":
        return Locale(identifier: "zh-Hans")
    case "zh-hant":
        return Locale(identifier: "zh-Hant")
    case "pt-br":
        return Locale(identifier: "pt-BR")
    default:
        return Locale(identifier: language)
    }
}

func codexBarLocalizedInteger(_ value: Int) -> String {
    value.formatted(.number.locale(codexBarLocalizedLocale()))
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

func resetCodexBarLocalizationCache() {
    LocalizationBundleCache.reset()
}

#if DEBUG
func codexBarLocalizedBundleForTesting() -> Bundle {
    localizedBundle()
}

func resetCodexBarLocalizationCacheForTesting() {
    resetCodexBarLocalizationCache()
}
#endif

func configureUsageFormatterLocalizationProvider() {
    UsageFormatter.setLocalizationProvider { key in
        let resourceBundle = codexBarLocalizationResourceBundle()
        return codexBarLocalizedString(key, bundle: localizedBundle(), resourceBundle: resourceBundle)
    }
    UsageFormatter.setLocaleProvider {
        codexBarLocalizedLocale()
    }
}
