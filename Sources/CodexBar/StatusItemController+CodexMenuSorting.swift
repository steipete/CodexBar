import AppKit
import CodexBarCore
import Foundation

extension StatusItemController {
    func makeCodexSortControlItem(menu: NSMenu) -> NSMenuItem {
        let view = CodexAccountSortControlView(
            mode: self.settings.codexMenuAccountSortMode,
            width: self.menuCardWidth(for: self.store.enabledProvidersForDisplay(), menu: menu),
            onStep: { [weak self, weak menu] delta in
                guard let self, let menu else { return }
                self.stepCodexMenuSortMode(delta)
                let provider = self.menuProvider(for: menu)
                self.populateMenu(menu, provider: provider)
                self.markMenuFresh(menu)
            })
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = true
        return item
    }

    func sortedCodexVisibleAccounts(
        _ accounts: [CodexVisibleAccount],
        cachedSnapshots: [String: CodexVisibleAccountUsageSnapshot]) -> [CodexVisibleAccount]
    {
        Self.sortedCodexVisibleAccounts(
            accounts,
            cachedSnapshots: cachedSnapshots,
            mode: self.settings.codexMenuAccountSortMode)
    }

    static func sortedCodexVisibleAccounts(
        _ accounts: [CodexVisibleAccount],
        cachedSnapshots: [String: CodexVisibleAccountUsageSnapshot],
        mode: CodexMenuAccountSortMode) -> [CodexVisibleAccount]
    {
        guard accounts.count > 1 else { return accounts }
        return accounts.sorted { lhs, rhs in
            self.compareCodexVisibleAccounts(lhs, rhs, cachedSnapshots: cachedSnapshots, mode: mode)
        }
    }

    static func compareCodexVisibleAccounts(
        _ lhs: CodexVisibleAccount,
        _ rhs: CodexVisibleAccount,
        cachedSnapshots: [String: CodexVisibleAccountUsageSnapshot],
        mode: CodexMenuAccountSortMode) -> Bool
    {
        let lhsName = lhs.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsName = rhs.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lhsSnapshot = cachedSnapshots[lhs.id]?.snapshot
        let rhsSnapshot = cachedSnapshots[rhs.id]?.snapshot

        func fallbackNameAscending() -> Bool {
            lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
        }

        func compareOptional<T: Comparable>(_ lhsValue: T?, _ rhsValue: T?, ascending: Bool) -> Bool {
            switch (lhsValue, rhsValue) {
            case let (lhs?, rhs?):
                if lhs != rhs {
                    return ascending ? lhs < rhs : lhs > rhs
                }
                return fallbackNameAscending()
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return fallbackNameAscending()
            }
        }

        switch mode {
        case .accountNameAscending:
            return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
        case .accountNameDescending:
            return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedDescending
        case .sessionLeftHighToLow:
            return compareOptional(
                lhsSnapshot?.primary?.remainingPercent,
                rhsSnapshot?.primary?.remainingPercent,
                ascending: false)
        case .sessionResetSoonestFirst:
            return compareOptional(lhsSnapshot?.primary?.resetsAt, rhsSnapshot?.primary?.resetsAt, ascending: true)
        case .weeklyLeftHighToLow:
            return compareOptional(
                lhsSnapshot?.secondary?.remainingPercent,
                rhsSnapshot?.secondary?.remainingPercent,
                ascending: false)
        case .weeklyResetSoonestFirst:
            return compareOptional(
                lhsSnapshot?.secondary?.resetsAt,
                rhsSnapshot?.secondary?.resetsAt,
                ascending: true)
        }
    }

    func stepCodexMenuSortMode(_ delta: Int) {
        let modes = CodexMenuAccountSortMode.allCases
        guard let currentIndex = modes.firstIndex(of: self.settings.codexMenuAccountSortMode), !modes.isEmpty else {
            self.settings.codexMenuAccountSortMode = .default
            return
        }
        let count = modes.count
        let nextIndex = (currentIndex + delta % count + count) % count
        self.settings.codexMenuAccountSortMode = modes[nextIndex]
    }
}
