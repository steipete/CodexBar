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

    func sortedTokenAccountSnapshots(
        _ snapshots: [TokenAccountUsageSnapshot],
        provider: UsageProvider) -> [TokenAccountUsageSnapshot]
    {
        guard provider == .codex, snapshots.count > 1 else { return snapshots }
        let mode = self.settings.codexMenuAccountSortMode
        return snapshots.sorted { lhs, rhs in
            self.compareTokenAccountSnapshots(lhs, rhs, mode: mode)
        }
    }

    func compareTokenAccountSnapshots(
        _ lhs: TokenAccountUsageSnapshot,
        _ rhs: TokenAccountUsageSnapshot,
        mode: CodexMenuAccountSortMode) -> Bool
    {
        let lhsName = lhs.account.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsName = rhs.account.label.trimmingCharacters(in: .whitespacesAndNewlines)

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
                lhs.snapshot?.primary?.remainingPercent,
                rhs.snapshot?.primary?.remainingPercent,
                ascending: false)
        case .sessionResetSoonestFirst:
            return compareOptional(lhs.snapshot?.primary?.resetsAt, rhs.snapshot?.primary?.resetsAt, ascending: true)
        case .weeklyLeftHighToLow:
            return compareOptional(
                lhs.snapshot?.secondary?.remainingPercent,
                rhs.snapshot?.secondary?.remainingPercent,
                ascending: false)
        case .weeklyResetSoonestFirst:
            return compareOptional(
                lhs.snapshot?.secondary?.resetsAt,
                rhs.snapshot?.secondary?.resetsAt,
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
