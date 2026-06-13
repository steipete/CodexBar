import AppKit
import Testing
@testable import CodexBar

@MainActor
struct StatusMenuAppearanceTests {
    private final class AppearanceTrackingMenu: NSMenu {
        var appearanceAssignmentCount = 0

        override var appearance: NSAppearance? {
            didSet {
                self.appearanceAssignmentCount += 1
            }
        }
    }

    @Test
    func `pin uses the exact application effective appearance`() {
        let menu = NSMenu()
        let effectiveAppearance = NSApplication.shared.effectiveAppearance

        StatusMenuAppearance.pin(menu)

        #expect(menu.appearance === effectiveAppearance)
    }

    @Test
    func `pin reassigns an appearance even when its name is unchanged`() throws {
        let menu = AppearanceTrackingMenu()
        let appearance = try #require(NSAppearance(named: .aqua))
        menu.appearance = appearance
        let assignmentsBeforePin = menu.appearanceAssignmentCount

        StatusMenuAppearance.pin(menu, to: appearance)

        #expect(menu.appearance === appearance)
        #expect(menu.appearanceAssignmentCount == assignmentsBeforePin + 1)
    }

    @Test
    func `submenus inherit each refreshed root appearance`() throws {
        let menu = NSMenu()
        let submenu = NSMenu()
        let item = NSMenuItem(title: "Details", action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)

        let lightAppearance = try #require(NSAppearance(named: .aqua))
        StatusMenuAppearance.pin(menu, to: lightAppearance)
        #expect(menu.appearance === lightAppearance)
        #expect(submenu.appearance == nil)
        #expect(submenu.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)

        let darkAppearance = try #require(NSAppearance(named: .darkAqua))
        StatusMenuAppearance.pin(menu, to: darkAppearance)
        #expect(menu.appearance === darkAppearance)
        #expect(submenu.appearance == nil)
        #expect(submenu.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }
}
