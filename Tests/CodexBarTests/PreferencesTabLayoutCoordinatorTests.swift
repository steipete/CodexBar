import Testing
@testable import CodexBar

struct PreferencesTabLayoutCoordinatorTests {
    @Test
    func `binding selection defers one layout and suppresses observed duplicate`() {
        var coordinator = PreferencesTabLayoutCoordinator()

        let beganSelection = coordinator.beginBindingSelection(from: .general, to: .providers)
        #expect(beganSelection)
        #expect(coordinator.bindingHandledTab == .providers)
        let observedLayout = coordinator.layoutForObservedSelection(.providers, current: .providers)
        #expect(observedLayout == nil)
        #expect(coordinator.bindingHandledTab == nil)
        #expect(coordinator.layoutForDeferredSelection(.providers, current: .providers) == .providers)
    }

    @Test
    func `same tab selection schedules no layout`() {
        var coordinator = PreferencesTabLayoutCoordinator()

        let beganSelection = coordinator.beginBindingSelection(from: .general, to: .general)
        #expect(!beganSelection)
        #expect(coordinator.bindingHandledTab == nil)
    }

    @Test
    func `programmatic selection performs observed layout`() {
        var coordinator = PreferencesTabLayoutCoordinator()

        let observedLayout = coordinator.layoutForObservedSelection(.about, current: .about)
        #expect(observedLayout == .about)
        #expect(coordinator.bindingHandledTab == nil)
    }

    @Test
    func `rapid tab clicks ignore stale observation and deferred layout`() {
        var coordinator = PreferencesTabLayoutCoordinator()

        let beganProviders = coordinator.beginBindingSelection(from: .general, to: .providers)
        let beganAbout = coordinator.beginBindingSelection(from: .providers, to: .about)
        let staleObservedLayout = coordinator.layoutForObservedSelection(.providers, current: .about)
        #expect(beganProviders)
        #expect(beganAbout)
        #expect(staleObservedLayout == nil)
        #expect(coordinator.bindingHandledTab == .about)
        #expect(coordinator.layoutForDeferredSelection(.providers, current: .about) == nil)
        let currentObservedLayout = coordinator.layoutForObservedSelection(.about, current: .about)
        #expect(currentObservedLayout == nil)
        #expect(coordinator.layoutForDeferredSelection(.about, current: .about) == .about)
    }

    @Test
    func `programmatic selection replaces pending binding layout`() {
        var coordinator = PreferencesTabLayoutCoordinator()

        let beganSelection = coordinator.beginBindingSelection(from: .general, to: .providers)
        let programmaticLayout = coordinator.layoutForObservedSelection(.advanced, current: .advanced)
        #expect(beganSelection)
        #expect(programmaticLayout == .advanced)
        #expect(coordinator.bindingHandledTab == nil)
        #expect(coordinator.layoutForDeferredSelection(.providers, current: .advanced) == nil)
    }
}
