import AppKit
import Testing
@testable import CodexBar

@MainActor
struct StatusItemCreationOrderingTests {
    @MainActor
    private final class Item: StatusItemConfiguring {
        var events: [String] = []
        var autosaveName: String! {
            didSet { self.events.append("name:\(self.autosaveName ?? "nil")") }
        }

        var length: CGFloat {
            didSet { self.events.append("length:\(self.length)") }
        }

        var button: NSStatusBarButton? {
            nil
        }

        init(length: CGFloat) {
            self.length = length
            self.events.append("create:\(length)")
        }
    }

    @Test(arguments: [true, false])
    func `initial and recovery creation name the item before sizing or registration`(merged: Bool) {
        let identity: StatusItemController.StatusItemIdentity = merged ? .merged : .provider(.codex)
        let defaults = InMemoryUserDefaults()
        let key = MenuBarStatusItemPlacementPreflight.preferredPositionKey(autosaveName: identity.autosaveName)
        for _ in 0..<2 {
            defaults.set(Double.infinity, forKey: key)
            let item = StatusItemController.makeStatusItem(
                create: { length in
                    #expect(defaults.object(forKey: key) == nil)
                    return Item(length: length)
                },
                identity: identity,
                defaults: defaults,
                legacyDefaultItemIndex: nil,
                onCreated: { item in
                    #expect(item.autosaveName == identity.autosaveName)
                    #expect(item.length == 0)
                    item.events.append("registered")
                })
            #expect(item.events == [
                "create:0.0", "name:\(identity.autosaveName)", "registered", "length:-1.0",
            ])
        }
    }

    @Test
    func `registration rendering keeps its chosen width`() {
        let item = StatusItemController.makeStatusItem(
            create: { Item(length: $0) },
            identity: .provider(.codex),
            defaults: InMemoryUserDefaults(),
            legacyDefaultItemIndex: nil,
            onCreated: { item in
                #expect(item.autosaveName == "codexbar-codex")
                item.length = 44
            })
        #expect(item.length == 44)
    }

    @Test
    func `placement repair rejects positions beyond every attached screen width`() {
        let frames = (0..<3).map { CGRect(x: $0 * 2560, y: 0, width: 2560, height: 1440) }
        let key = MenuBarStatusItemPlacementPreflight.preferredPositionKey(autosaveName: "codexbar-codex")
        let defaults = InMemoryUserDefaults(values: [key: 6247])
        let bound = MenuBarStatusItemPlacementPreflight.currentMaximumPreferredPosition(screenFrames: frames)

        #expect(bound == 2560)
        #expect(MenuBarStatusItemPlacementPreflight.prepare(
            defaults: defaults,
            autosaveName: "codexbar-codex",
            maximumPreferredPosition: bound))
        #expect(defaults.object(forKey: key) == nil)
    }

    @Test
    func `pure placement repair scopes keys and respects display padding`() {
        let prefix = MenuBarStatusItemPlacementPreflight.preferredPositionPrefix
        let values: [String: Any] = [
            prefix + "codexbar-codex": 6247,
            prefix + "Item-1": 6247,
            prefix + "codexbar-claude": 6247,
            prefix + "Item-0": 6247,
            prefix + "codexbar-merged": 3072,
            MenuBarStatusItemDefaultsRepair.didRepairKey: true,
        ]
        let names = ["codexbar-codex", "Item-1", "codexbar-merged", "codexbar-missing"]
        #expect(MenuBarStatusItemPlacementPreflight.keysToClear(
            values, autosaveNames: names, screenWidths: [1440, 2560]) == [prefix + "codexbar-codex", prefix + "Item-1"])
        #expect(MenuBarStatusItemPlacementPreflight.keysToClear(
            values, autosaveNames: names, screenWidths: []).isEmpty)
        #expect(MenuBarStatusItemPlacementPreflight.keysToClear(
            values, autosaveNames: names, screenWidths: [6400]).isEmpty)

        let defaults = InMemoryUserDefaults(values: values)
        #expect(MenuBarStatusItemPlacementPreflight.prepare(
            defaults: defaults,
            autosaveName: "codexbar-codex",
            legacyDefaultItemIndex: 1,
            maximumPreferredPosition: 2560))
        #expect(defaults.dictionaryRepresentation() as NSDictionary == values.filter {
            $0.key != prefix + "codexbar-codex" && $0.key != prefix + "Item-1"
        } as NSDictionary)
    }

    @Test
    func `pure placement repair rejects invalid values with or without displays`() {
        let name = "codexbar-merged"
        let key = MenuBarStatusItemPlacementPreflight.preferredPositionKey(autosaveName: name)
        let invalid: [Any] = ["invalid", 0, -1, Double.nan, Double.infinity, -Double.infinity]
        for value in invalid {
            for widths in [[], [2560.0]] {
                #expect(MenuBarStatusItemPlacementPreflight.keysToClear(
                    [key: value], autosaveNames: [name], screenWidths: widths) == [key])
            }
        }
        #expect(MenuBarStatusItemPlacementPreflight.keysToClear(
            [key: 3072.5], autosaveNames: [name], screenWidths: [2560]) == [key])
    }

    @Test
    func `visibility repair retains boolean number and unknown value semantics`() {
        let key = "NSStatusItem VisibleCC codexbar-merged"
        for value: Any in [false, 0, NSNumber(value: false)] {
            #expect(MenuBarStatusItemDefaultsRepair.shouldRepair(key: key, value: value))
        }
        for value: Any in [true, 1, NSNumber(value: true), "false"] {
            #expect(!MenuBarStatusItemDefaultsRepair.shouldRepair(key: key, value: value))
        }
        #expect(!MenuBarStatusItemDefaultsRepair.shouldRepair(key: key, value: nil))
    }
}
