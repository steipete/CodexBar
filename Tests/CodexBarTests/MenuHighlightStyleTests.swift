import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MenuHighlightStyleTests {
    @Test
    func `system highlight remains the default`() {
        let defaults = InMemoryUserDefaults()
        #expect(MenuHighlightStyle.customAppearance(defaults: defaults) == nil)
    }

    @Test
    func `custom highlight loads color and opacity`() throws {
        let defaults = InMemoryUserDefaults()
        defaults.set(true, forKey: MenuHighlightStyle.enabledKey)
        defaults.set("#E8B078", forKey: MenuHighlightStyle.colorKey)
        defaults.set(0.42, forKey: MenuHighlightStyle.opacityKey)

        let appearance = try #require(MenuHighlightStyle.customAppearance(defaults: defaults))
        #expect(appearance.color == ProviderColor(hex: 0xE8B078))
        #expect(appearance.opacity == 0.42)
    }

    @Test
    func `invalid stored values fall back and opacity stays bounded`() throws {
        let defaults = InMemoryUserDefaults()
        defaults.set(true, forKey: MenuHighlightStyle.enabledKey)
        defaults.set("invalid", forKey: MenuHighlightStyle.colorKey)
        defaults.set(2.0, forKey: MenuHighlightStyle.opacityKey)

        let appearance = try #require(MenuHighlightStyle.customAppearance(defaults: defaults))
        #expect(appearance.color == MenuHighlightStyle.defaultColor)
        #expect(appearance.opacity == 1)
    }
}
