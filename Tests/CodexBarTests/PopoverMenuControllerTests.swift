import AppKit
import SwiftUI
import Testing
@testable import CodexBar

@MainActor @Suite struct PopoverMenuControllerTests {
    @Test(arguments: [
        (visibleHeight: CGFloat(300), expectedMaximumHeight: CGFloat(320)),
        (visibleHeight: CGFloat(600), expectedMaximumHeight: CGFloat(491)),
        (visibleHeight: CGFloat(1000), expectedMaximumHeight: CGFloat(720)),
    ])
    func showPreparationUpdatesViewModel(
        visibleHeight: CGFloat,
        expectedMaximumHeight: CGFloat)
    {
        let vm = MenuViewModel()
        let controller = PopoverMenuController(viewModel: vm) { EmptyContentProbe() }
        controller.prepareForShowForTesting(visibleHeight: visibleHeight)
        #expect(vm.isVisible == true)
        #expect(vm.maximumPopoverHeight == expectedMaximumHeight)
        controller.close()
        #expect(vm.isVisible == false)
    }

    @Test func escapeKeyClosesPopover() {
        let vm = MenuViewModel()
        let controller = PopoverMenuController(viewModel: vm) { EmptyContentProbe() }
        controller.prepareForShowForTesting(visibleHeight: 600)
        let handled = controller.handleKeyDownForTesting(keyCode: 53) // Esc
        #expect(handled == true)
        #expect(vm.isVisible == false)
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

    // MARK: - #1 transient 双触发防抖

    @Test func toggleAfterCloseIsSuppressedWithinSameRunloop() {
        let vm = MenuViewModel()
        let controller = PopoverMenuController(viewModel: vm) { EmptyContentProbe() }
        controller.prepareForShowForTesting(visibleHeight: 600)
        #expect(vm.isVisible == true)
        controller.simulatePopoverDidCloseForTesting() // 模拟 transient 外部点击关闭
        #expect(vm.isVisible == false)
        #expect(controller.canOpenFromToggleForTesting() == false)
    }
}

private struct EmptyContentProbe: View {
    var body: some View {
        Color.clear.frame(width: 1, height: 1)
    }
}
