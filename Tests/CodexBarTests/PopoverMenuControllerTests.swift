import Testing
import AppKit
import SwiftUI
@testable import CodexBar

@MainActor @Suite struct PopoverMenuControllerTests {
    @Test func showAndCloseUpdatesViewModelVisibility() {
        let vm = MenuViewModel()
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let button = statusItem.button!
        let controller = PopoverMenuController(viewModel: vm) { EmptyContentProbe() }
        controller.show(relativeTo: button)
        #expect(vm.isVisible == true)
        controller.close()
        #expect(vm.isVisible == false)
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @Test func escapeKeyClosesPopover() {
        let vm = MenuViewModel()
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let button = statusItem.button!
        let controller = PopoverMenuController(viewModel: vm) { EmptyContentProbe() }
        controller.show(relativeTo: button)
        let handled = controller.handleKeyDownForTesting(keyCode: 53) // Esc
        #expect(handled == true)
        #expect(vm.isVisible == false)
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @Test func nonEscapeKeyNotHandled() {
        let vm = MenuViewModel()
        let controller = PopoverMenuController(viewModel: vm) { EmptyContentProbe() }
        let handled = controller.handleKeyDownForTesting(keyCode: 0) // 'a'
        #expect(handled == false)
    }

    // MARK: - Task 1.4 字符级快捷键派发

    @Test func commandRTriggersRefresh() {
        var fired = false
        let controller = PopoverMenuController(viewModel: MenuViewModel()) { EmptyContentProbe() }
        controller.onRefresh = { fired = true }
        #expect(controller.handleForTesting(characters: "r", modifiers: .command) == true)
        #expect(fired)
    }

    @Test func commandCommaTriggersSettings() {
        var fired = false
        let controller = PopoverMenuController(viewModel: MenuViewModel()) { EmptyContentProbe() }
        controller.onSettings = { fired = true }
        #expect(controller.handleForTesting(characters: ",", modifiers: .command) == true)
        #expect(fired)
    }

    @Test func commandQTriggersQuit() {
        var fired = false
        let controller = PopoverMenuController(viewModel: MenuViewModel()) { EmptyContentProbe() }
        controller.onQuit = { fired = true }
        #expect(controller.handleForTesting(characters: "q", modifiers: .command) == true)
        #expect(fired)
    }

    @Test func commandDigitSelectsIndex() {
        var picked: Int?
        let controller = PopoverMenuController(viewModel: MenuViewModel()) { EmptyContentProbe() }
        controller.onSelectIndex = { picked = $0 }
        #expect(controller.handleForTesting(characters: "3", modifiers: .command) == true)
        #expect(picked == 2)
    }

    @Test func arrowsNavigate() {
        var dir: StatusItemMenuProviderNavigationDirection?
        let controller = PopoverMenuController(viewModel: MenuViewModel()) { EmptyContentProbe() }
        controller.onNavigate = { dir = $0 }
        #expect(controller.handleKeyDownForTesting(keyCode: 124) == true) // →
        #expect(dir == .next)
        #expect(controller.handleKeyDownForTesting(keyCode: 123) == true) // ←
        #expect(dir == .previous)
    }

    @Test func unhandledKeyReturnsFalse() {
        let controller = PopoverMenuController(viewModel: MenuViewModel()) { EmptyContentProbe() }
        #expect(controller.handleForTesting(characters: "x", modifiers: .command) == false)
    }
}

private struct EmptyContentProbe: View {
    var body: some View { Color.clear.frame(width: 1, height: 1) }
}
