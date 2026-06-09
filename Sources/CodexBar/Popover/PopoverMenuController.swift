import AppKit
import SwiftUI

/// 用 NSPopover(.transient) 承载持久 SwiftUI 根视图，替代 statusItem.menu。
/// 阶段 1.3：加入本地键盘 monitor，Esc 关闭面板；阶段 1.4 接入更多快捷键。
@MainActor
final class PopoverMenuController<Content: View> {
    private let viewModel: MenuViewModel
    private let popover: NSPopover
    private let hostingController: NSHostingController<Content>
    // nonisolated(unsafe) 允许在 deinit（非 MainActor）中直接读写，
    // 实际写入只发生在 @MainActor 方法中，线程安全由调用方保证。
    nonisolated(unsafe) private var keyMonitor: Any?

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

    deinit {
        // deinit 不在 MainActor，直接操作 monitor 避免跨隔离调用
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    var isShown: Bool { self.popover.isShown }

    func show(relativeTo button: NSStatusBarButton) {
        guard !self.popover.isShown else { return }
        self.viewModel.setVisible(true)
        self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover.contentViewController?.view.window?.makeKey()
        self.installKeyMonitor()
    }

    func close() {
        self.removeKeyMonitor()
        self.popover.performClose(nil)
        self.viewModel.setVisible(false)
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if self.popover.isShown { self.close() } else { self.show(relativeTo: button) }
    }

    // MARK: - 键盘 monitor

    private func installKeyMonitor() {
        guard self.keyMonitor == nil else { return }
        self.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.handleKeyDown(keyCode: event.keyCode, modifiers: event.modifierFlags) {
                return nil // 吞掉已处理事件
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = self.keyMonitor {
            NSEvent.removeMonitor(monitor)
            self.keyMonitor = nil
        }
    }

    /// 处理面板可见期间的按键。返回 true 表示已处理（事件被吞）。
    /// 阶段 1.3 仅处理 Esc；阶段 1.4 接入 Cmd+R/,/Q、←→、Cmd+1..9。
    @discardableResult
    private func handleKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        if keyCode == 53 { // Esc
            self.close()
            return true
        }
        return false
    }

    /// 测试接缝：直接驱动按键处理，绕过真实 NSEvent monitor。
    @discardableResult
    func handleKeyDownForTesting(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        self.handleKeyDown(keyCode: keyCode, modifiers: modifiers)
    }
}
