import Foundation

/// User overrides for the provider brand colors.
///
/// `~/.codexbar/config.json` is the source of truth, and it reaches the app and the `codexbar serve`
/// dashboard directly. The sandboxed widget cannot read that file, so the app mirrors the resolved
/// map into the App Group defaults for it.
///
/// Descriptor colors stay compile-time constants and are never written over. An override is therefore
/// always removable, and removal restores the shipped color.
public enum ProviderAccentColors {
    static let defaultsKey = "providerAccentColors"

    /// Resolving the App Group container is a sandbox round trip, and the widget colors every row from
    /// this map, so the resolved suite is memoized. The suite itself still reflects later writes.
    private static let defaultsLock = NSLock()
    private nonisolated(unsafe) static var cachedDefaults: (bundleID: String?, suite: UserDefaults?)?

    private static func defaults(bundleID: String?) -> UserDefaults? {
        self.defaultsLock.lock()
        defer { self.defaultsLock.unlock() }
        if let cached = self.cachedDefaults, cached.bundleID == bundleID {
            return cached.suite
        }
        let suite = AppGroupSupport.sharedDefaults(bundleID: bundleID)
        self.cachedDefaults = (bundleID, suite)
        return suite
    }

    /// Collects the overrides a config carries. Values that do not parse as `#RRGGBB` are dropped, so a
    /// hand-edited config file degrades to the shipped color instead of failing to load.
    public static func overrides(in config: CodexBarConfig) -> [ProviderInstanceID: ProviderColor] {
        config.providers.reduce(into: [:]) { result, provider in
            guard let raw = provider.accentColor,
                  let color = ProviderColor(hexString: raw)
            else { return }
            result[provider.id] = color
        }
    }

    /// Reads the overrides the app last mirrored into the App Group. Used by the widget extension.
    public static func sharedOverrides(
        bundleID: String? = Bundle.main.bundleIdentifier) -> [ProviderInstanceID: ProviderColor]
    {
        guard let defaults = self.defaults(bundleID: bundleID) else { return [:] }
        return self.decode(defaults.dictionary(forKey: self.defaultsKey) as? [String: String] ?? [:])
    }

    /// Reads a single mirrored override. Returns nil when the provider keeps its shipped color.
    public static func sharedOverride(
        for instanceID: ProviderInstanceID,
        bundleID: String? = Bundle.main.bundleIdentifier) -> ProviderColor?
    {
        guard let defaults = self.defaults(bundleID: bundleID),
              let raw = (defaults.dictionary(forKey: self.defaultsKey) as? [String: String])?[instanceID.rawValue]
        else { return nil }
        return ProviderColor(hexString: raw)
    }

    /// Mirrors the overrides into the App Group. Returns true when the stored value changed, so the
    /// caller can reload widget timelines only when a color actually moved.
    @discardableResult
    public static func mirrorToSharedDefaults(
        _ overrides: [ProviderInstanceID: ProviderColor],
        bundleID: String? = Bundle.main.bundleIdentifier) -> Bool
    {
        guard let defaults = self.defaults(bundleID: bundleID) else { return false }
        let encoded = self.encode(overrides)
        let existing = defaults.dictionary(forKey: self.defaultsKey) as? [String: String] ?? [:]
        guard encoded != existing else { return false }
        if encoded.isEmpty {
            defaults.removeObject(forKey: self.defaultsKey)
        } else {
            defaults.set(encoded, forKey: self.defaultsKey)
        }
        return true
    }

    static func encode(_ overrides: [ProviderInstanceID: ProviderColor]) -> [String: String] {
        overrides.reduce(into: [:]) { result, entry in
            result[entry.key.rawValue] = entry.value.hexString
        }
    }

    static func decode(_ raw: [String: String]) -> [ProviderInstanceID: ProviderColor] {
        raw.reduce(into: [:]) { result, entry in
            guard let instanceID = ProviderInstanceID(rawValue: entry.key),
                  let color = ProviderColor(hexString: entry.value)
            else { return }
            result[instanceID] = color
        }
    }
}
