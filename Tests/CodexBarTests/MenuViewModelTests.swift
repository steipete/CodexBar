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
        vm.select(.overview)            // already .overview
        #expect(vm.contentVersion == 0) // no change → no bump
    }

    @Test func markVisibleTogglesState() {
        let vm = MenuViewModel()
        vm.setVisible(true)
        #expect(vm.isVisible == true)
        vm.setVisible(false)
        #expect(vm.isVisible == false)
    }
}
