import CodexBarCore
import Foundation

extension SettingsStore {
    func shouldShowCodexMenuSortControl(for provider: UsageProvider) -> Bool {
        provider == .codex && self.showAllTokenAccountsInMenu && self.tokenAccounts(for: .codex).count > 1
    }
}
