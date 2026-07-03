import CodexBarCore

enum ProviderCookieSourceUI {
    static let keychainDisabledPrefixKey =
        "Keychain access is disabled in Advanced, so browser cookie import is unavailable."

    @MainActor
    static func cachedTrailingText(provider: UsageProvider) -> String? {
        guard let entry = CookieHeaderCache.loadForDisplay(provider: provider) else { return nil }
        return self.cachedTrailingText(entry: entry)
    }

    @MainActor
    static func cachedTrailingText(entry: CookieHeaderCache.Entry) -> String {
        let when = entry.storedAt.relativeDescription()
        return L("Cached: %1$@ • %2$@", entry.sourceLabel, when)
    }

    static func options(allowsOff: Bool, keychainDisabled: Bool) -> [ProviderSettingsPickerOption] {
        var options: [ProviderSettingsPickerOption] = []
        if !keychainDisabled {
            options.append(ProviderSettingsPickerOption(
                id: ProviderCookieSource.auto.rawValue,
                title: ProviderCookieSource.auto.displayName))
        }
        options.append(ProviderSettingsPickerOption(
            id: ProviderCookieSource.manual.rawValue,
            title: ProviderCookieSource.manual.displayName))
        if allowsOff {
            options.append(ProviderSettingsPickerOption(
                id: ProviderCookieSource.off.rawValue,
                title: ProviderCookieSource.off.displayName))
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
        let localizedAuto = self.localizedSubtitle(auto)
        let localizedManual = self.localizedSubtitle(manual)
        let localizedOff = self.localizedSubtitle(off)
        if keychainDisabled {
            return source == .off
                ? localizedOff
                : "\(L(self.keychainDisabledPrefixKey)) \(localizedManual)"
        }
        switch source {
        case .auto:
            return localizedAuto
        case .manual:
            return localizedManual
        case .off:
            return localizedOff
        }
    }

    private static func localizedSubtitle(_ subtitle: String) -> String {
        let trimmed = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let source = trimmed.removing(prefix: "Paste a Cookie header or cURL capture from ", suffix: ".") {
            return L("Paste a Cookie header or cURL capture from %@.", source)
        }
        if let source = trimmed.removing(prefix: "Paste a Cookie header or full cURL capture from ", suffix: ".") {
            return L("Paste a Cookie header or full cURL capture from %@.", source)
        }
        if let source = trimmed.removing(prefix: "Paste a Cookie header captured from ", suffix: ".") {
            return L("Paste a Cookie header captured from %@.", source)
        }
        if let source = trimmed.removing(prefix: "Paste a Cookie header from ", suffix: ".") {
            return L("Paste a Cookie header from %@.", source)
        }
        if let token = trimmed.removing(prefix: "Paste a full cookie header or the ", suffix: " value.") {
            return L("Paste a full cookie header or the %@ value.", token)
        }
        if let source = trimmed.removing(prefix: "Paste a Cookie or Authorization header from ", suffix: ".") {
            return L("Paste a Cookie or Authorization header from %@.", source)
        }
        if let token = trimmed.removing(prefix: "Paste the ", suffix: " value or a full Cookie header.") {
            return L("Paste the %@ value or a full Cookie header.", token)
        }
        if let token = trimmed.removing(prefix: "Manually paste an ", suffix: " from a browser session.") {
            return L("Manually paste an %@ from a browser session.", token)
        }
        if let token = trimmed.removing(
            prefix: "Uses username + password to login and obtain an ",
            suffix: " automatically.")
        {
            return L("Uses username + password to login and obtain an %@ automatically.", token)
        }
        if let parts = trimmed.removingTwoParts(prefix: "Paste the ", separator: " JSON bundle from ", suffix: ".") {
            return L("Paste the %@ JSON bundle from %@.", parts.0, parts.1)
        }
        if let provider = trimmed.removing(prefix: "Disable ", suffix: " dashboard cookie usage.") {
            return L("Disable %@ dashboard cookie usage.", provider)
        }
        if let provider = trimmed.removing(prefix: "", suffix: " cookies are disabled.") {
            return L("%@ cookies are disabled.", provider)
        }
        if let provider = trimmed.removing(prefix: "", suffix: " authentication is disabled.") {
            return L("%@ authentication is disabled.", provider)
        }
        if let provider = trimmed.removing(prefix: "", suffix: " web API access is disabled.") {
            return L("%@ web API access is disabled.", provider)
        }
        return L(trimmed)
    }
}

extension String {
    fileprivate func removing(prefix: String, suffix: String) -> String? {
        guard self.hasPrefix(prefix), self.hasSuffix(suffix) else { return nil }
        let start = self.index(self.startIndex, offsetBy: prefix.count)
        let end = self.index(self.endIndex, offsetBy: -suffix.count)
        guard start <= end else { return nil }
        return String(self[start..<end])
    }

    fileprivate func removingTwoParts(prefix: String, separator: String, suffix: String) -> (String, String)? {
        guard let value = self.removing(prefix: prefix, suffix: suffix),
              let range = value.range(of: separator)
        else { return nil }
        return (String(value[..<range.lowerBound]), String(value[range.upperBound...]))
    }
}
