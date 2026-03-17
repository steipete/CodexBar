import CodexBarCore

enum ProviderCookieSourceUI {
    static let keychainDisabledPrefix =
        AppStrings.tr("Keychain access is disabled in Advanced, so browser cookie import is unavailable.")

    static func options(allowsOff: Bool, keychainDisabled: Bool) -> [ProviderSettingsPickerOption] {
        var options: [ProviderSettingsPickerOption] = []
        if !keychainDisabled {
            options.append(ProviderSettingsPickerOption(
                id: ProviderCookieSource.auto.rawValue,
                title: AppStrings.cookieSource(.auto)))
        }
        options.append(ProviderSettingsPickerOption(
            id: ProviderCookieSource.manual.rawValue,
            title: AppStrings.cookieSource(.manual)))
        if allowsOff {
            options.append(ProviderSettingsPickerOption(
                id: ProviderCookieSource.off.rawValue,
                title: AppStrings.cookieSource(.off)))
        }
        return options
    }

    static func subtitle(
        source: ProviderCookieSource,
        keychainDisabled: Bool,
        auto: String,
        manual: String,
        off: String) -> String
    {
        if keychainDisabled {
            return source == .off ? off : "\(self.keychainDisabledPrefix) \(manual)"
        }
        switch source {
        case .auto:
            return auto
        case .manual:
            return manual
        case .off:
            return off
        }
    }
}
