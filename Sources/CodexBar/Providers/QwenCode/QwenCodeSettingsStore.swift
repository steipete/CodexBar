import CodexBarCore
import Foundation

extension SettingsStore {
    func qwencodeSettingsSnapshot() -> ProviderSettingsSnapshot.QwenCodeProviderSettings {
        ProviderSettingsSnapshot.QwenCodeProviderSettings(
            dailyRequestLimit: self.qwencodeRequestLimitValue())
    }

    private func qwencodeRequestLimitValue() -> Int? {
        let raw = self.qwenCodeDailyRequestLimit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return Int(raw)
    }
}
