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

    @Test func removingProviderPopoverClearsControllerAndVisibility() throws {
        let controller = try makePerProviderController()
        defer { controller.releaseStatusItemsForTesting() }
        controller.ensureProviderPopover(for: .claude)
        let viewModel = try #require(controller.providerMenuViewModels[.claude])
        viewModel.setVisible(true)

        controller.removeProviderPopover(for: .claude)

        #expect(controller.providerPopoverControllers[.claude] == nil)
        #expect(controller.providerMenuViewModels[.claude] == nil)
        #expect(viewModel.isVisible == false)
    }
}

@MainActor
private func makePerProviderController() throws -> StatusItemController {
    let suite = "PopoverPerProviderTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    let settings = SettingsStore(
        userDefaults: defaults,
        configStore: testConfigStore(suiteName: suite),
        zaiTokenStore: NoopZaiTokenStore(),
        syntheticTokenStore: NoopSyntheticTokenStore())
    settings.statusChecksEnabled = false
    settings.refreshFrequency = .manual
    let fetcher = UsageFetcher(environment: [:])
    let store = UsageStore(
        fetcher: fetcher,
        browserDetection: BrowserDetection(cacheTTL: 0),
        settings: settings)
    return StatusItemController(
        store: store,
        settings: settings,
        account: AccountInfo(email: nil, plan: nil),
        updater: DisabledUpdaterController(),
        preferencesSelection: PreferencesSelection(),
        statusBar: .system)
}
