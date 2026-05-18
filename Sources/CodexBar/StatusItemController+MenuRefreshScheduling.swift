import AppKit
import CodexBarCore
import QuartzCore

extension StatusItemController {
    func performMenuMutationWithoutAnimation(_ updates: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        updates()
    }

    func deferSwitcherMenuRebuildIfStillVisible(_ menu: NSMenu, provider: UsageProvider?) {
        self.providerSwitcherUpdateToken &+= 1
        let updateToken = self.providerSwitcherUpdateToken
        Task { @MainActor [weak self, weak menu] in
            await Task.yield()
            guard let self, let menu else { return }
            guard self.providerSwitcherUpdateToken == updateToken else { return }
            guard self.openMenus[ObjectIdentifier(menu)] != nil else { return }
            self.closeHostedSubviewMenusForParentSwitch()
            self.rebuildOpenMenuIfStillVisible(menu, provider: provider)
        }
    }

    private func closeHostedSubviewMenusForParentSwitch() {
        let hostedMenus = self.openMenus.values.filter { self.isHostedSubviewMenu($0) }
        for hostedMenu in hostedMenus {
            hostedMenu.cancelTrackingWithoutAnimation()
            self.forgetClosedMenu(hostedMenu)
        }
    }
}
