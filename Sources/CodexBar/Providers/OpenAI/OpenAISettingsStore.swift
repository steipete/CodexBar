import CodexBarCore
import Foundation

extension SettingsStore {
    var openAIUsageDataSource: ProviderSourceMode {
        get { self.configSnapshot.providerConfig(for: .openai)?.source ?? .auto }
        set {
            self.updateProviderConfig(provider: .openai) { entry in
                entry.source = newValue == .auto ? nil : newValue
            }
            self.logProviderModeChange(provider: .openai, field: "usageSource", value: newValue.rawValue)
        }
    }
}
