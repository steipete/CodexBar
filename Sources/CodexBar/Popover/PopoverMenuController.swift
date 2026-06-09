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

    // MARK: - 注入回调（Task 1.4）

    var onRefresh: (() -> Void)?
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var onNavigate: ((StatusItemMenuProviderNavigationDirection) -> Void)?
    var onSelectIndex: ((Int) -> Void)?

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
            if self.handle(
                characters: event.charactersIgnoringModifiers,
                keyCode: event.keyCode,
                modifiers: event.modifierFlags
            ) {
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

    /// 统一按键处理。characters 用 charactersIgnoringModifiers。返回 true 表示已处理（吞掉事件）。
    @discardableResult
    private func handle(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let command = modifiers.intersection([.command, .option, .control, .shift]) == .command
        // Cmd 组合（字符级，兼容键盘布局）
        if command, let ch = characters?.lowercased() {
            switch ch {
            case "r":
                self.onRefresh?()
                return true
            case ",":
                self.onSettings?()
                return true
            case "q":
                self.onQuit?()
                return true
            default:
                if let n = Int(ch), (1...9).contains(n) {
                    self.onSelectIndex?(n - 1)
                    return true
                }
            }
        }
        // 非修饰键（按 keyCode）
        switch keyCode {
        case 53:  // Esc
            self.close()
            return true
        case 123: // ←
            self.onNavigate?(.previous)
            return true
        case 124: // →
            self.onNavigate?(.next)
            return true
        default:
            return false
        }
    }

    /// 测试接缝（keyCode 级）：直接驱动按键处理，绕过真实 NSEvent monitor。
    /// 保持阶段 1.3 的 Esc/箭头测试可用。
    @discardableResult
    func handleKeyDownForTesting(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        self.handle(characters: nil, keyCode: keyCode, modifiers: modifiers)
    }

    /// 测试接缝（字符级）：直接驱动字符快捷键处理，绕过真实 NSEvent monitor。
    @discardableResult
    func handleForTesting(characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        self.handle(characters: characters, keyCode: 0, modifiers: modifiers)
    }
}
