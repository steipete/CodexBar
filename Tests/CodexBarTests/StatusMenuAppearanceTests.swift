import AppKit
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuAppearanceTests {
    private final class AppearanceSource: NSObject {
        @objc dynamic var appearance: NSAppearance

        init(_ appearance: NSAppearance) {
            self.appearance = appearance
            super.init()
        }
    }

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

    @Test
    func `previously opened nested menus follow a refreshed root`() throws {
        let root = NSMenu()
        let submenu = NSMenu()
        let nestedMenu = NSMenu()
        let child = NSMenuItem(title: "Cost history", action: nil, keyEquivalent: "")
        child.submenu = submenu
        root.addItem(child)
        let nested = NSMenuItem(title: "Daily details", action: nil, keyEquivalent: "")
        nested.submenu = nestedMenu
        submenu.addItem(nested)

        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        StatusMenuAppearance.pin(root, to: light)
        StatusMenuAppearance.pin(submenu, to: light)
        StatusMenuAppearance.pin(nestedMenu, to: light)

        StatusMenuAppearance.pin(root, to: dark)

        #expect(root.appearance === dark)
        #expect(submenu.appearance == nil)
        #expect(nestedMenu.appearance == nil)
        #expect(submenu.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        #expect(nestedMenu.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    @Test
    func `appearance observation refreshes a cached menu before it opens`() async throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        let source = AppearanceSource(light)
        let menu = NSMenu()
        StatusMenuAppearance.pin(menu, to: light)
        let observer = StatusMenuAppearanceObserver(source: source, appearance: \.appearance) {
            StatusMenuAppearance.pin(menu, to: $0)
        }
        defer { observer.stop() }

        source.appearance = dark
        await Self.drainAppearanceQueue()

        #expect(menu.appearance === dark)
        source.appearance = light
        await Self.drainAppearanceQueue()
        #expect(menu.appearance === light)
    }

    @Test
    func `appearance bursts coalesce the deferred refresh and use the latest exact appearance`() async throws {
        let source = try AppearanceSource(#require(NSAppearance(named: .aqua)))
        let dark = try #require(NSAppearance(named: .darkAqua))
        let contrast = try #require(NSAppearance(named: .accessibilityHighContrastDarkAqua))
        var applied: [NSAppearance] = []
        let observer = StatusMenuAppearanceObserver(source: source, appearance: \.appearance) { applied.append($0) }
        defer { observer.stop() }

        source.appearance = dark
        source.appearance = contrast
        await Self.drainAppearanceQueue()

        #expect(applied.count == 3)
        #expect(applied.allSatisfy { $0 === contrast })
    }

    @Test
    func `stopping appearance observation cancels queued and future updates`() async throws {
        let light = try #require(NSAppearance(named: .aqua))
        let source = AppearanceSource(light)
        var refreshes = 0
        let observer = StatusMenuAppearanceObserver(source: source, appearance: \.appearance) { _ in refreshes += 1 }
        source.appearance = try #require(NSAppearance(named: .darkAqua))
        observer.stop()
        await Self.drainAppearanceQueue()
        source.appearance = light
        await Self.drainAppearanceQueue()

        #expect(refreshes == 0)
    }

    @Test
    func `stopping during appearance refresh prevents the deferred update`() async throws {
        let source = try AppearanceSource(#require(NSAppearance(named: .aqua)))
        var refreshes = 0
        var observer: StatusMenuAppearanceObserver?
        observer = StatusMenuAppearanceObserver(source: source, appearance: \.appearance) { _ in
            refreshes += 1
            observer?.stop()
        }
        defer { observer = nil }
        source.appearance = try #require(NSAppearance(named: .darkAqua))
        await Self.drainAppearanceQueue()

        #expect(refreshes == 1)
    }

    private static func drainAppearanceQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}
