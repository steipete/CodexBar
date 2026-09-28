import AppKit
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct MenuBarStatusItemPlacementPreservationTests {
    @Test
    func `hide or removal cannot replace a valid placement with an invalid position`() {
        let key = MenuBarStatusItemPlacementPreflight.preferredPositionKey(autosaveName: "codexbar-codex")
        let invalid: [Any] = [6247, 0, -1, Double.nan, Double.infinity, "invalid"]
        for value in invalid {
            let defaults = InMemoryUserDefaults(values: [key: 548])
            MenuBarStatusItemPlacementPreservation.preservingPreferredPosition(
                autosaveName: "codexbar-codex", defaults: defaults, maximumPreferredPosition: 2560)
            {
                defaults.set(value, forKey: key)
            }
            #expect(defaults.double(forKey: key) == 548)
        }
    }

    @Test(arguments: [true, false])
    func `hide or removal never restores a corrupt saved placement`(cleared: Bool) {
        let key = MenuBarStatusItemPlacementPreflight.preferredPositionKey(autosaveName: "codexbar-codex")
        let defaults = InMemoryUserDefaults(values: [key: 6247])
        MenuBarStatusItemPlacementPreservation.preservingPreferredPosition(
            autosaveName: "codexbar-codex", defaults: defaults, maximumPreferredPosition: 2560)
        {
            if cleared { defaults.removeObject(forKey: key) }
        }
        #expect(defaults.object(forKey: key) == nil)
    }

    @Test
    func `invalid new placement without a saved position is removed only for the owned identity`() {
        let key = MenuBarStatusItemPlacementPreflight.preferredPositionKey(autosaveName: "codexbar-codex")
        let otherKey = MenuBarStatusItemPlacementPreflight.preferredPositionKey(autosaveName: "codexbar-claude")
        let defaults = InMemoryUserDefaults(values: [otherKey: 6247])
        MenuBarStatusItemPlacementPreservation.preservingPreferredPosition(
            autosaveName: "codexbar-codex", defaults: defaults, maximumPreferredPosition: 2560)
        {
            defaults.set(6247, forKey: key)
        }
        #expect(defaults.object(forKey: key) == nil)
        #expect(defaults.integer(forKey: otherKey) == 6247)
    }

    @Test(arguments: [nil, 6400.0])
    func `large valid positions survive when displays are unknown or wide enough`(maximum: Double?) {
        let key = MenuBarStatusItemPlacementPreflight.preferredPositionKey(autosaveName: "codexbar-codex")
        let defaults = InMemoryUserDefaults(values: [key: 6247])
        MenuBarStatusItemPlacementPreservation.preservingPreferredPosition(
            autosaveName: "codexbar-codex", defaults: defaults, maximumPreferredPosition: maximum)
        {
            defaults.removeObject(forKey: key)
        }
        #expect(defaults.integer(forKey: key) == 6247)
    }

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
