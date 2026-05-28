import AppKit

extension StatusItemController {
    func beginMenuTokenCostDeferral(_ menu: NSMenu, reason: String) {
        let key = ObjectIdentifier(menu)
        guard !self.tokenCostDeferredMenuIDs.contains(key) else { return }
        self.tokenCostDeferredMenuIDs.insert(key)
        self.store.beginInteractiveMenuTokenCostDeferral(reason: reason)
    }

    func endMenuTokenCostDeferral(_ menu: NSMenu, reason: String) {
        let key = ObjectIdentifier(menu)
        guard self.tokenCostDeferredMenuIDs.remove(key) != nil else { return }
        self.store.endInteractiveMenuTokenCostDeferral(reason: reason)
    }
}
