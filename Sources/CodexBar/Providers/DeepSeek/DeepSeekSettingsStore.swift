import CodexBarCore
import Foundation

extension SettingsStore {
    func deepseekProfileID(apiKey: String?) -> String {
        _ = self.configRevision
        _ = self.providerDetailSettingsRevision
        guard let config = self.config.providerConfig(for: .deepseek),
              let profileID = config.sanitizedDeepSeekProfileID
        else { return "" }
        let accountID = self.selectedTokenAccount(for: .deepseek)?.id
        let expectedScope = DeepSeekSettingsReader.profileScope(selectedTokenAccountID: accountID, apiKey: apiKey)
        guard let expectedScope, config.sanitizedDeepSeekProfileScope == expectedScope else { return "" }
        return profileID
    }

    func setDeepSeekProfileID(_ newValue: String, apiKey: String?) {
        let profileID = self.normalizedConfigValue(newValue)
        let profileScope = DeepSeekSettingsReader.profileScope(
            selectedTokenAccountID: self.selectedTokenAccount(for: .deepseek)?.id,
            apiKey: apiKey)
        guard profileID == nil || profileScope != nil else { return }
        self.updateProviderDetailConfig(provider: .deepseek) { entry in
            entry.deepseekProfileID = profileID
            entry.deepseekProfileScope = profileID == nil ? nil : profileScope
        }
    }
}
