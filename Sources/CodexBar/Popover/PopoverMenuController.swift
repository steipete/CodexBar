import AppKit
import SwiftUI

/// 用 NSPopover(.transient) 承载持久 SwiftUI 根视图，替代 statusItem.menu。
/// 阶段 0 仅实现显隐 + view model 可见性同步；键盘/dismiss 监听在后续任务加入。
@MainActor
final class PopoverMenuController<Content: View> {
    private let viewModel: MenuViewModel
    private let popover: NSPopover
    private let hostingController: NSHostingController<Content>

    init(viewModel: MenuViewModel, contentView: () -> Content) {
        self.viewModel = viewModel
        let hosting = NSHostingController(rootView: contentView())
        self.hostingController = hosting
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = hosting
        self.popover = popover
    }

    var isShown: Bool { self.popover.isShown }

    func show(relativeTo button: NSStatusBarButton) {
        guard !self.popover.isShown else { return }
        self.viewModel.setVisible(true)
        self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover.contentViewController?.view.window?.makeKey()
    }

    func close() {
        self.popover.performClose(nil)
        self.viewModel.setVisible(false)
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if self.popover.isShown { self.close() } else { self.show(relativeTo: button) }
    }
}
