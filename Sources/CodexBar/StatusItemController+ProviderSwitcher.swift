import AppKit

extension StatusItemController {
    func providerSwitcherContentStartIndex(in menu: NSMenu) -> Int {
        menu.items.first?.view is ProviderSwitcherView ? 2 : 0
    }

    @discardableResult
    func selectOpenProviderSwitcherSegment(at index: Int) -> Bool {
        for menu in self.openMenus.values {
            guard let switcherView = menu.items.first?.view as? ProviderSwitcherView,
                  switcherView.handleKeyboardSelection(at: index)
            else {
                continue
            }
            self.applyIcon(phase: nil)
            return true
        }
        return false
    }
}
