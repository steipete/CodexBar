import AppKit
import Testing
@testable import CodexBar

@MainActor
struct MenuBarWindowAlignmentTests {
    @Test(arguments: [false, true])
    func `stacked meters align with or without a promoted icon`(promotedIcon: Bool) throws {
        let fixture = MenuBarLayoutRendererTests()
        let first: [MenuBarLayoutToken] = promotedIcon
            ? [.icon, .progressBar(window: .session)] : [.progressBar(window: .session)]
        let output = MenuBarLayoutRenderer().render(
            layout: .init(lines: [first, [.progressBar(window: .weekly)]]),
            data: fixture.data(sessionWindowMinutes: 30),
            icon: promotedIcon ? NSImage(size: NSSize(width: 16, height: 16)) : nil,
            options: fixture.options())
        let origins = Self.origins(of: "\u{FFFC}", in: output.attributedTitle)
        #expect(origins.count == 2)
        #expect(try abs(#require(origins.first) - #require(origins.last)) < 0.1)
        #expect((output.leadingIcon != nil) == promotedIcon)
    }

    @Test
    func `composed provider meters share the widest rendered label column`() throws {
        let fixture = MenuBarLayoutRendererTests()
        let renderer = MenuBarLayoutRenderer()
        let top = renderer.render(
            layout: .init(lines: [[.progressBar(window: .session)]]),
            data: fixture.data(sessionWindowMinutes: 30),
            icon: nil,
            options: fixture.options(forceStackedStyle: true))
        let bottom = renderer.render(
            layout: .init(lines: [[.progressBar(window: .weekly)]]),
            data: fixture.data(provider: .claude),
            icon: nil,
            options: fixture.options(forceStackedStyle: true))
        let output = MenuBarLayoutRenderer.composeStackedProviderRows(
            top: top, bottom: bottom, topProviderName: "Codex", bottomProviderName: "Claude")
        let origins = Self.origins(of: "\u{FFFC}", in: output.attributedTitle)
        #expect(origins.count == 2)
        #expect(try abs(#require(origins.first) - #require(origins.last)) < 0.1)
    }

    @Test
    func `composing a leading label with a named row retains each natural origin`() {
        let fixture = MenuBarLayoutRendererTests()
        let renderer = MenuBarLayoutRenderer()
        let top = renderer.render(
            layout: .init(lines: [[.progressBar(window: .session)]]),
            data: fixture.data(sessionWindowMinutes: 30),
            icon: nil,
            options: fixture.options(forceStackedStyle: true))
        let bottom = renderer.render(
            layout: .init(lines: [[.providerName, .progressBar(window: .weekly)]]),
            data: fixture.data(provider: .claude),
            icon: nil,
            options: fixture.options(forceStackedStyle: true))
        let output = MenuBarLayoutRenderer.composeStackedProviderRows(
            top: top, bottom: bottom, topProviderName: "Codex", bottomProviderName: "Claude")
        let natural = Self.origins(of: "\u{FFFC}", in: top.attributedTitle)
            + Self.origins(of: "\u{FFFC}", in: bottom.attributedTitle)
        let composed = Self.origins(of: "\u{FFFC}", in: output.attributedTitle)
        #expect(natural.count == 2)
        #expect(composed.count == 2)
        #expect(zip(natural, composed).allSatisfy { abs($0 - $1) < 0.1 })
    }

    @Test
    func `stacked percentages share the meter column`() throws {
        let fixture = MenuBarLayoutRendererTests()
        let output = MenuBarLayoutRenderer().render(
            layout: .init(lines: [[.percent(window: .session)], [.progressBar(window: .weekly)]]),
            data: fixture.data(sessionWindowMinutes: 30),
            icon: nil,
            options: fixture.options())
        let percent = try #require(Self.origins(of: "25%", in: output.attributedTitle).first)
        let meter = try #require(Self.origins(of: "\u{FFFC}", in: output.attributedTitle).first)
        #expect(abs(percent - meter) < 0.1)
    }

    @Test
    func `unlabeled and nonleading layouts retain natural spacing`() {
        let fixture = MenuBarLayoutRendererTests()
        let renderer = MenuBarLayoutRenderer()
        let hidden = renderer.render(
            layout: .init(lines: [[.percent(window: .session)], [.percent(window: .weekly)]]),
            data: fixture.data(),
            icon: nil,
            options: fixture.options(showWindowLabels: false))
        #expect(hidden.attributedTitle.string == "25%\n60%")
        let layouts: [[MenuBarLayoutToken]] = [
            [.providerName, .progressBar(window: .session)],
            [.space, .progressBar(window: .session)],
            [.icon, .space, .progressBar(window: .session)],
        ]
        for first in layouts {
            let output = renderer.render(
                layout: .init(lines: [first, [.progressBar(window: .weekly)]]),
                data: fixture.data(),
                icon: NSImage(size: NSSize(width: 16, height: 16)),
                options: fixture.options())
            if first.first == .icon {
                #expect(output.leadingIcon != nil)
            }
            let firstOnly = renderer.render(
                layout: .init(lines: [first, [.providerName]]),
                data: fixture.data(),
                icon: NSImage(size: NSSize(width: 16, height: 16)),
                options: fixture.options())
            let lastOnly = renderer.render(
                layout: .init(lines: [[.providerName], [.progressBar(window: .weekly)]]),
                data: fixture.data(),
                icon: NSImage(size: NSSize(width: 16, height: 16)),
                options: fixture.options())
            let natural = Self.origins(of: "\u{FFFC}", in: firstOnly.attributedTitle)
                + Self.origins(of: "\u{FFFC}", in: lastOnly.attributedTitle)
            let actual = Self.origins(of: "\u{FFFC}", in: output.attributedTitle)
            #expect(natural.count == 2)
            #expect(actual.count == 2)
            #expect(zip(natural, actual).allSatisfy { abs($0 - $1) < 0.1 })
        }
    }

    private static func origins(of needle: String, in title: NSAttributedString) -> [CGFloat] {
        let storage = NSTextStorage(attributedString: title)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 1000, height: 1000))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let text = title.string as NSString
        var range = NSRange(location: 0, length: text.length)
        var origins: [CGFloat] = []
        while range.length > 0 {
            let match = text.range(of: needle, range: range)
            guard match.location != NSNotFound else { break }
            let glyph = manager.glyphIndexForCharacter(at: match.location)
            origins.append(manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX
                + manager.location(forGlyphAt: glyph).x)
            range = NSRange(location: NSMaxRange(match), length: text.length - NSMaxRange(match))
        }
        return origins
    }
}
