import AppKit
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct MenuBarStatusItemPlacementPreservationTests {
    @Test
    func `preserving preferred position restores a value the body cleared`() {
        let defaults = InMemoryUserDefaults()
        let key = MenuBarStatusItemPlacementPreflight.preferredPositionKey(autosaveName: "codexbar-claude")
        defaults.set(845.0, forKey: key)

        let result = MenuBarStatusItemPlacementPreservation.preservingPreferredPosition(
            autosaveName: "codexbar-claude",
            defaults: defaults)
        {
            defaults.removeObject(forKey: key)
            return "done"
        }

        #expect(result == "done")
        #expect(defaults.double(forKey: key) == 845)
    }

    @Test
    func `preserving preferred position leaves a missing value unset`() {
        let defaults = InMemoryUserDefaults()
        let key = MenuBarStatusItemPlacementPreflight.preferredPositionKey(autosaveName: "codexbar-claude")

        MenuBarStatusItemPlacementPreservation.preservingPreferredPosition(
            autosaveName: "codexbar-claude",
            defaults: defaults) {}

        #expect(defaults.object(forKey: key) == nil)
    }

    @Test
    func `preserving preferred position keeps a value the body rewrote`() {
        let defaults = InMemoryUserDefaults()
        let key = MenuBarStatusItemPlacementPreflight.preferredPositionKey(autosaveName: "codexbar-claude")
        defaults.set(845.0, forKey: key)

        MenuBarStatusItemPlacementPreservation.preservingPreferredPosition(
            autosaveName: "codexbar-claude",
            defaults: defaults)
        {
            defaults.set(900.0, forKey: key)
        }

        #expect(defaults.double(forKey: key) == 900)
    }

    @Test
    func `preserving preferred position ignores empty autosave names`() {
        let defaults = InMemoryUserDefaults()
        let key = MenuBarStatusItemPlacementPreflight.preferredPositionKey(autosaveName: "")
        defaults.set(845.0, forKey: key)

        MenuBarStatusItemPlacementPreservation.preservingPreferredPosition(autosaveName: "", defaults: defaults) {
            defaults.removeObject(forKey: key)
        }

        #expect(defaults.object(forKey: key) == nil)
    }
}
