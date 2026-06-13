import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite struct PopoverPerProviderTests {
    // MARK: - MenuViewModel.singleProvider 工厂

    @Test func singleProviderFactorySetProviders() {
        let vm = MenuViewModel.singleProvider(.claude)
        #expect(vm.providers == [.claude])
    }

    @Test func singleProviderFactoryNoOverview() {
        let vm = MenuViewModel.singleProvider(.claude)
        #expect(vm.includesOverview == false)
    }

    @Test func singleProviderFactorySelectionIsProvider() {
        let vm = MenuViewModel.singleProvider(.codex)
        #expect(vm.selection == .provider(.codex))
    }

    @Test func singleProviderFactoryNoSelectionChangedCallback() {
        let vm = MenuViewModel.singleProvider(.openai)
        // 单 provider 不接 onSelectionChanged，不应触发持久化
        #expect(vm.onSelectionChanged == nil)
    }

    @Test func singleProviderFactorySelectDoesNotCrash() {
        let vm = MenuViewModel.singleProvider(.claude)
        // 调用 select 不应崩溃（onSelectionChanged 为 nil 时）
        let newSelection = ProviderSwitcherSelection.provider(.openai)
        vm.select(newSelection)
        #expect(vm.selection == newSelection)
    }

    @Test func fallbackFactoryDoesNotExposeProviderContent() {
        let vm = MenuViewModel.fallback(statusItemProvider: .codex)

        #expect(vm.isFallback)
        #expect(vm.providers.isEmpty)
        #expect(vm.selection == .provider(.codex))
    }
}
