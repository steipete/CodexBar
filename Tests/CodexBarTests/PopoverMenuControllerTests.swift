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
}

private struct EmptyContentProbe: View {
    var body: some View { Color.clear.frame(width: 1, height: 1) }
}
