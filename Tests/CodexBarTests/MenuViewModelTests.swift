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
        vm.includesOverview = true
        // 起点 .overview → next → .provider(codex) → next → .provider(claude) → next → 回 .overview
        #expect(vm.selection == .overview)
        vm.selectNext(); #expect(vm.selection == .provider(.codex))
        vm.selectNext(); #expect(vm.selection == .provider(.claude))
        vm.selectNext(); #expect(vm.selection == .overview)
    }

    @Test func selectPreviousWrapsBackward() {
        let vm = MenuViewModel()
        vm.providers = [.codex, .claude]
        vm.includesOverview = true
        vm.selectPrevious(); #expect(vm.selection == .provider(.claude)) // overview ← 回绕到末尾
    }

    @Test func selectProviderAtIndexBounds() {
        let vm = MenuViewModel()
        vm.providers = [.codex, .claude]
        vm.selectProvider(atIndex: 1); #expect(vm.selection == .provider(.claude))
        vm.selectProvider(atIndex: 9) // 越界：无变化
        #expect(vm.selection == .provider(.claude))
    }

    // MARK: - Task 2.5 includesOverview

    @Test func includesOverviewFalseSkipsOverviewInNavigation() {
        let vm = MenuViewModel()
        vm.providers = [.codex, .claude]
        vm.includesOverview = false
        // stops = [.provider(.codex), .provider(.claude)]
        // 起点 .overview 不在 stops 中，firstIndex 返回 nil，降级 index 0。
        // selectNext: delta=+1 → index 1 → .provider(.claude)
        vm.selectNext(); #expect(vm.selection == .provider(.claude))
        // 已在 stops 中：.provider(.claude) → index 1，delta=+1 → index 0 → .provider(.codex)
        vm.selectNext(); #expect(vm.selection == .provider(.codex))
        // .provider(.codex) → index 0，delta=+1 → index 1 → .provider(.claude)；永不经过 overview
        vm.selectNext(); #expect(vm.selection == .provider(.claude))
    }

    @Test func includesOverviewTrueAddsOverviewToNavigationStops() {
        let vm = MenuViewModel()
        vm.providers = [.codex]
        vm.includesOverview = true
        // stops = [.overview, .provider(.codex)]
        // 起点 .overview → next → .provider(.codex) → next → 回 .overview
        #expect(vm.selection == .overview)
        vm.selectNext(); #expect(vm.selection == .provider(.codex))
        vm.selectNext(); #expect(vm.selection == .overview)
    }
}
