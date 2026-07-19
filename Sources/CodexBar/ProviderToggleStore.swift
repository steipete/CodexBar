import CodexBarCore
import Foundation

struct ProviderToggleStore {
    private let userDefaults: UserDefaults
    private let key = "providerToggles"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func isEnabled(metadata: ProviderMetadata) -> Bool {
        self.load()[metadata.cliName] ?? metadata.defaultEnabled
    }

    func setEnabled(_ enabled: Bool, metadata: ProviderMetadata) {
        var toggles = self.load()
        toggles[metadata.cliName] = enabled
        self.userDefaults.set(toggles, forKey: self.key)
    }

    private func load() -> [String: Bool] {
        (self.userDefaults.dictionary(forKey: self.key) as? [String: Bool]) ?? [:]
    }

    func purgeLegacyKeys() {
        self.userDefaults.removeObject(forKey: "showCodexUsage")
        self.userDefaults.removeObject(forKey: "showClaudeUsage")
    }
}
