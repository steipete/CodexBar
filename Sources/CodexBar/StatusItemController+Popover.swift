import AppKit

// MARK: - Popover 菜单接入（合并模式）

//
// 把 popover 相关的接入逻辑从 StatusItemController 主体抽出，集中于此扩展，
// 既保持主类体在 swiftlint type_body_length 限制内，也便于后续阶段在此扩展。
// 仅当 `usePopoverMenu` 开关开启时这些路径才生效；关闭时主类走原有 NSMenu 逻辑。

extension StatusItemController {
    /// 特性开关：是否启用 NSPopover 菜单（替代 NSMenu）。
    var usePopoverMenu: Bool {
        self.settings.usePopoverMenu
    }

    /// 合并模式下安装 popover：清掉 statusItem.menu，懒创建 PopoverMenuController 并接线快捷键回调，
    /// 再把状态项按钮点击（含右键）路由到 handleStatusItemClick。仅在 usePopoverMenu 开启时调用。
    func attachMergedPopover() {
        self.statusItem.menu = nil
        if self.popoverMenuController == nil {
            self.menuViewModel.providers = self.store.enabledProvidersForDisplay()
            let vm = self.menuViewModel
            let store = self.store
            self.popoverMenuController = PopoverMenuController(viewModel: vm) { [weak self] in
                PopoverRootView(
                    viewModel: vm,
                    store: store,
                    makeCardModel: { [weak self] provider in self?.menuCardModel(for: provider) })
            }
            self.wirePopoverShortcutCallbacks()
        }
        self.statusItem.button?.target = self
        self.statusItem.button?.action = #selector(self.handleStatusItemClick(_:))
        // 右键也触发 action，使右键可弹出 popover
        self.statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// 接线 popover 的键盘快捷键回调（只在控制器首次创建时设一次，弱引用防环）。
    private func wirePopoverShortcutCallbacks() {
        self.popoverMenuController?.onRefresh = { [weak self] in
            self?.refreshNow()
            self?.popoverMenuController?.close()
        }
        self.popoverMenuController?.onSettings = { [weak self] in
            self?.showSettingsGeneral()
            self?.popoverMenuController?.close()
        }
        self.popoverMenuController?.onQuit = { [weak self] in
            self?.quit()
        }
        self.popoverMenuController?.onNavigate = { [weak self] direction in
            switch direction {
            case .next: self?.menuViewModel.selectNext()
            case .previous: self?.menuViewModel.selectPrevious()
            }
        }
        self.popoverMenuController?.onSelectIndex = { [weak self] index in
            self?.menuViewModel.selectProvider(atIndex: index)
        }
    }
}
