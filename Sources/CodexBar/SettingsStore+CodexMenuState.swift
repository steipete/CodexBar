import CodexBarCore
import Foundation

extension SettingsStore {
    func shouldShowCodexMenuDisplayModeToggle(for provider: UsageProvider) -> Bool {
        provider == .codex && self.codexVisibleAccountProjection.visibleAccounts.count > 1
    }

    func shouldShowCodexMenuSortControl(for provider: UsageProvider) -> Bool {
        provider == .codex && self.codexMenuDisplayMode == .all && self.codexVisibleAccountProjection.visibleAccounts
            .count > 1
    }
}
