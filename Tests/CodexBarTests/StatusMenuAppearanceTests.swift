import AppKit
import Testing
@testable import CodexBar

@MainActor
struct StatusMenuAppearanceTests {
    @Test
    func `pin uses the exact application effective appearance`() {
        let menu = NSMenu()
        let effectiveAppearance = NSApplication.shared.effectiveAppearance

        StatusMenuAppearance.pin(menu)

        #expect(menu.appearance === effectiveAppearance)
    }

    @Test
    func `pin replaces a distinct appearance with the same name`() throws {
        let menu = NSMenu()
        let initialAppearance = try #require(NSAppearance(named: .aqua))
        let replacementAppearance = try #require(NSAppearance(appearanceNamed: .aqua, bundle: .main))
        #expect(initialAppearance.name == replacementAppearance.name)
        #expect(initialAppearance !== replacementAppearance)
        menu.appearance = initialAppearance

        StatusMenuAppearance.pin(menu, to: replacementAppearance)

        #expect(menu.appearance === replacementAppearance)
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
