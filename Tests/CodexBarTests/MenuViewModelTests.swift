import Testing
@testable import CodexBar

@MainActor @Suite struct MenuViewModelTests {
    @Test func defaultsToFirstProviderNotVisible() {
        let vm = MenuViewModel()
        #expect(vm.isVisible == false)
        #expect(vm.selection == .overview)
    }

    @Test func selectingProviderBumpsContentVersionOnce() {
        let vm = MenuViewModel()
        vm.providers = [.codex, .claude]
        let v0 = vm.contentVersion
        vm.select(.provider(.claude))
        #expect(vm.selection == .provider(.claude))
        #expect(vm.contentVersion == v0 + 1)
    }

    @Test func selectingSameValueDoesNotBump() {
        let vm = MenuViewModel()
        vm.select(.overview) // already .overview
        #expect(vm.contentVersion == 0) // no change → no bump
    }

    @Test func markVisibleTogglesState() {
        let vm = MenuViewModel()
        vm.setVisible(true)
        #expect(vm.isVisible == true)
        vm.setVisible(false)
        #expect(vm.isVisible == false)
    }

    // MARK: - Task 1.4 导航助手

    @Test func selectNextCyclesThroughOverviewAndProviders() {
        let vm = MenuViewModel()
        vm.providers = [.codex, .claude]
        // 起点 .overview → next → .provider(codex) → next → .provider(claude) → next → 回 .overview
        #expect(vm.selection == .overview)
        vm.selectNext(); #expect(vm.selection == .provider(.codex))
        vm.selectNext(); #expect(vm.selection == .provider(.claude))
        vm.selectNext(); #expect(vm.selection == .overview)
    }

    @Test func selectPreviousWrapsBackward() {
        let vm = MenuViewModel()
        vm.providers = [.codex, .claude]
        vm.selectPrevious(); #expect(vm.selection == .provider(.claude)) // overview ← 回绕到末尾
    }

    @Test func selectProviderAtIndexBounds() {
        let vm = MenuViewModel()
        vm.providers = [.codex, .claude]
        vm.selectProvider(atIndex: 1); #expect(vm.selection == .provider(.claude))
        vm.selectProvider(atIndex: 9) // 越界：无变化
        #expect(vm.selection == .provider(.claude))
    }
}
