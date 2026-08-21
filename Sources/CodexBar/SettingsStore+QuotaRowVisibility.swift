import CodexBarCore
import Foundation

/// Pure set arithmetic behind the per-provider quota row visibility, kept separate from
/// `SettingsStore` so it can be covered without constructing a store (and its Keychain-backed
/// dependencies).
enum QuotaRowVisibilityState {
    static func hiddenIDs(in raw: [String: [String]], provider: UsageProvider) -> Set<String> {
        Set(raw[provider.rawValue] ?? [])
    }

    /// Raw storage with `id` hidden or shown for `provider`, or nil when nothing would change.
    /// Providers with nothing hidden drop out of the dictionary rather than keeping an empty list.
    static func updating(
        _ raw: [String: [String]],
        provider: UsageProvider,
        id: String,
        visible: Bool)
        -> [String: [String]]?
    {
        var hidden = self.hiddenIDs(in: raw, provider: provider)
        if visible {
            guard hidden.remove(id) != nil else { return nil }
        } else {
            guard hidden.insert(id).inserted else { return nil }
        }
        var updated = raw
        if hidden.isEmpty {
            updated.removeValue(forKey: provider.rawValue)
        } else {
            updated[provider.rawValue] = hidden.sorted()
        }
        return updated
    }

    /// Raw storage with every hidden row restored for `provider`, or nil when none were hidden.
    static func clearing(_ raw: [String: [String]], provider: UsageProvider) -> [String: [String]]? {
        var updated = raw
        guard updated.removeValue(forKey: provider.rawValue) != nil else { return nil }
        return updated
    }
}

/// Per-provider visibility for the individual quota rows a provider reports beyond its main
/// session/weekly lanes — Claude's model-scoped weekly limits (Fable, Design, …), Antigravity's
/// per-model quotas, and the equivalents on other providers.
///
/// Accounts commonly expose a dozen of these; hiding the ones the user never touches keeps the menu
/// readable without losing the underlying data. Nothing is filtered from fetches, quota warnings, or
/// history — only from the menu rows.
extension SettingsStore {
    var hiddenQuotaRowIDsRaw: [String: [String]] {
        get { self.defaultsState.hiddenQuotaRowIDsRaw }
        set {
            self.defaultsState.hiddenQuotaRowIDsRaw = newValue
            self.userDefaults.set(newValue, forKey: "hiddenQuotaRowIDs")
        }
    }

    func hiddenQuotaRowIDs(for provider: UsageProvider) -> Set<String> {
        QuotaRowVisibilityState.hiddenIDs(in: self.hiddenQuotaRowIDsRaw, provider: provider)
    }

    func isQuotaRowVisible(_ id: String, for provider: UsageProvider) -> Bool {
        !self.hiddenQuotaRowIDs(for: provider).contains(id)
    }

    func setQuotaRow(_ id: String, visible: Bool, for provider: UsageProvider) {
        guard let updated = QuotaRowVisibilityState.updating(
            self.hiddenQuotaRowIDsRaw,
            provider: provider,
            id: id,
            visible: visible)
        else { return }
        self.hiddenQuotaRowIDsRaw = updated
    }

    func showAllQuotaRows(for provider: UsageProvider) {
        guard let updated = QuotaRowVisibilityState.clearing(
            self.hiddenQuotaRowIDsRaw,
            provider: provider)
        else { return }
        self.hiddenQuotaRowIDsRaw = updated
    }
}
