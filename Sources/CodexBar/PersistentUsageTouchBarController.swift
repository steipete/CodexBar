import AppKit
import CodexBarCore
import SwiftUI

/// Keeps `CodexBarTouchBarView` visible on the physical Touch Bar at all times, not just
/// while a CodexBar window is key. Uses the same undocumented system-modal presentation
/// path as MTMR/Pock — see `SystemModalTouchBarRuntime`.
@MainActor
final class PersistentUsageTouchBarController: NSObject, NSTouchBarDelegate {
    private static let barIdentifier = NSTouchBar.CustomizationIdentifier("com.steipete.codexbar.persistentBar")
    private static let itemIdentifier = NSTouchBarItem.Identifier("com.steipete.codexbar.persistentItem")

    private let settings: SettingsStore
    private let store: UsageStore
    private var touchBar: NSTouchBar?

    init(settings: SettingsStore, store: UsageStore) {
        self.settings = settings
        self.store = store
    }

    func present() {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.customizationIdentifier = Self.barIdentifier
        bar.defaultItemIdentifiers = [Self.itemIdentifier]
        self.touchBar = bar

        SystemModalTouchBarRuntime.setCloseBoxVisibleWhenFrontmost(false)
        SystemModalTouchBarRuntime.presentSystemModal(
            bar,
            placement: 1,
            systemTrayItemIdentifier: Self.itemIdentifier)
    }

    func dismiss() {
        guard let touchBar else { return }
        SystemModalTouchBarRuntime.dismissSystemModal(touchBar)
        self.touchBar = nil
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == Self.itemIdentifier else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        let hosting = NSHostingView(rootView: CodexBarTouchBarView(settings: self.settings, store: self.store))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 30)
        item.view = hosting
        return item
    }
}
