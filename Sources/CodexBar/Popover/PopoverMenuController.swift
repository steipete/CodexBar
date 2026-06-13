import AppKit
import SwiftUI

/// 用 NSPopover(.transient) 承载持久 SwiftUI 根视图，替代 statusItem.menu。
/// 阶段 1.3：加入本地键盘 monitor，Esc 关闭面板；阶段 1.4 接入更多快捷键。
/// 阶段 review：通过 PopoverCloseDelegate 桥接 NSPopoverDelegate，
/// 处理 transient 自动关闭的状态同步与双触发防抖。
@MainActor
final class PopoverMenuController<Content: View> {
    private let viewModel: MenuViewModel
    private let popover: NSPopover
    private let hostingController: NSHostingController<Content>
    /// nonisolated(unsafe) 允许在 deinit（非 MainActor）中直接读写，
    /// 实际写入只发生在 @MainActor 方法中，线程安全由调用方保证。
    private nonisolated(unsafe) var keyMonitor: Any?

    /// 防止 transient 自动关闭后 button.action 立即重开的标志。
    /// handleDidClose() 置 true，下一 runloop tick 异步清除。
    private var suppressNextToggleOpen = false

    /// NSPopoverDelegate 桥接对象（泛型类不能直接遵从 @objc 协议）。
    private let closeDelegate: PopoverCloseDelegate

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
        // 桥接 delegate：接管关闭事件，同步 isVisible、移除 keyMonitor、防双触发
        let delegate = PopoverCloseDelegate()
        self.closeDelegate = delegate
        popover.delegate = delegate
        // 在 init 完成后，通过闭包把 handleDidClose 回调注入桥接对象
        // （此处 self 已完全初始化，可安全捕获）。
        // NSPopoverDelegate 回调由 AppKit 在主线程同步触发，必须用 assumeIsolated
        // 同步执行 handleDidClose——若用 Task 延迟，suppressNextToggleOpen 会在
        // 紧随其后的 button.action(toggle) 之后才置位，导致防双触发失效、面板点不掉。
        delegate.onDidClose = { [weak self] in
            MainActor.assumeIsolated {
                self?.handleDidClose()
            }
        }
    }

    deinit {
        // deinit 不在 MainActor，直接操作 monitor 避免跨隔离调用
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    var isShown: Bool {
        self.popover.isShown
    }

    func show(relativeTo button: NSStatusBarButton) {
        guard !self.popover.isShown else { return }
        let visibleHeight = button.window?.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 900
        self.prepareForShow(visibleHeight: visibleHeight)
        self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover.contentViewController?.view.window?.makeKey()
        self.installKeyMonitor()
    }

    /// 显式关闭：立即同步状态，再委托 performClose 触发 delegate（幂等安全）。
    func close() {
        self.removeKeyMonitor()
        self.viewModel.setVisible(false)
        self.popover.performClose(nil)
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if self.popover.isShown {
            self.close()
            return
        }
        // 刚因 transient 点击关闭时吞掉这次重开，避免闪烁
        guard self.canOpenFromToggle() else { return }
        self.show(relativeTo: button)
    }

    private func prepareForShow(visibleHeight: CGFloat) {
        self.viewModel.maximumPopoverHeight = min(720, max(320, floor(visibleHeight * 0.82)))
        self.viewModel.setVisible(true)
    }

    private func canOpenFromToggle() -> Bool {
        !self.suppressNextToggleOpen
    }

    // MARK: - 关闭统一清理（delegate 回调 + close() 共用）

    /// 统一清理：同步 isVisible、移除 monitor、设置防双触发标志（一个 runloop tick 后清除）。
    private func handleDidClose() {
        self.removeKeyMonitor()
        self.viewModel.setVisible(false)
        self.suppressNextToggleOpen = true
        DispatchQueue.main.async { [weak self] in
            self?.suppressNextToggleOpen = false
        }
    }

    /// 测试接缝：模拟 transient 外部点击关闭（驱动 handleDidClose），绕过真实 NSPopover。
    func simulatePopoverDidCloseForTesting() {
        self.handleDidClose()
    }

    func prepareForShowForTesting(visibleHeight: CGFloat) {
        self.prepareForShow(visibleHeight: visibleHeight)
    }

    func canOpenFromToggleForTesting() -> Bool {
        self.canOpenFromToggle()
    }

    // MARK: - 键盘 monitor

    private func installKeyMonitor() {
        guard self.keyMonitor == nil else { return }
        self.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.handle(
                characters: event.charactersIgnoringModifiers,
                keyCode: event.keyCode,
                modifiers: event.modifierFlags)
            {
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
        case 53: // Esc
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

// MARK: - NSPopoverDelegate 桥接

/// 非泛型 NSObject 子类，作为 NSPopoverDelegate 桥接对象。
/// 泛型类（PopoverMenuController）无法直接遵从 @objc 协议，故独立出来。
final class PopoverCloseDelegate: NSObject, NSPopoverDelegate {
    /// 关闭时回调，由 PopoverMenuController 在 init 后注入。
    var onDidClose: (() -> Void)?

    func popoverDidClose(_ notification: Notification) {
        self.onDidClose?()
    }
}
