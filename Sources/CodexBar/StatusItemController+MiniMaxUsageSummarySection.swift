import AppKit
import CodexBarCore

extension StatusItemController {
    func addMiniMaxUsageSummarySectionIfNeeded(to menu: NSMenu, context: MenuCardContext) {
        let provider = context.currentProvider
        let width = context.menuWidth
        guard self.addMiniMaxUsageSummaryMenuItemIfNeeded(to: menu, provider: provider, width: width) else {
            return
        }
        menu.addItem(.separator())
    }
}
