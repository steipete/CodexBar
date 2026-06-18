import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct IconRendererHideCrittersTests {
    private func pixels(_ image: NSImage) throws -> Data {
        try #require(image.tiffRepresentation)
    }

    private func icon(style: IconStyle, weeklyRemaining: Double? = 40, hideCritters: Bool) -> NSImage {
        IconRenderer.makeIcon(
            primaryRemaining: 60,
            weeklyRemaining: weeklyRemaining,
            creditsRemaining: nil,
            stale: false,
            style: style,
            hideCritters: hideCritters)
    }

    @Test(arguments: [
        IconStyle.codex,
        .claude,
        .gemini,
        .antigravity,
        .factory,
        .warp,
    ])
    func `hiding critters removes every decorated style twist`(style: IconStyle) throws {
        let decorated = self.icon(style: style, hideCritters: false)
        let plain = self.icon(style: style, hideCritters: true)

        #expect(try self.pixels(decorated) != self.pixels(plain))
    }

    @Test(arguments: [
        IconStyle.codex,
        .claude,
        .gemini,
        .antigravity,
        .factory,
        .warp,
    ])
    func `hidden decorated styles match plain capsule bars`(style: IconStyle) throws {
        let hidden = self.icon(style: style, hideCritters: true)
        let reference = self.icon(style: .cursor, hideCritters: true)

        #expect(try self.pixels(hidden) == self.pixels(reference))
    }

    @Test
    func `hiding critters removes warp eyes without weekly quota`() throws {
        let decorated = self.icon(style: .warp, weeklyRemaining: nil, hideCritters: false)
        let plain = self.icon(style: .warp, weeklyRemaining: nil, hideCritters: true)

        #expect(try self.pixels(decorated) != self.pixels(plain))
    }

    @Test
    func `hiding critters is a no-op for an undecorated style`() throws {
        // Cursor has no critter twist, so the flag must not alter its bars.
        let withFlag = self.icon(style: .cursor, hideCritters: true)
        let withoutFlag = self.icon(style: .cursor, hideCritters: false)

        #expect(try self.pixels(withFlag) == self.pixels(withoutFlag))
    }

    @Test
    func `morph icon honors hide critters at full progress`() throws {
        // At full progress the morph cross-fades into the bar icon, which carries
        // the Codex face. A distinct cache key must keep the two renders separate.
        let decorated = IconRenderer.makeMorphIcon(progress: 1, style: .codex, hideCritters: false)
        let plain = IconRenderer.makeMorphIcon(progress: 1, style: .codex, hideCritters: true)

        #expect(try self.pixels(decorated) != self.pixels(plain))
    }
}
