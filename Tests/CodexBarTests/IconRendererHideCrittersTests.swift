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

    @Test
    func `hiding critters changes the rendered bars for a decorated style`() throws {
        // Codex draws a face on the top bar; hiding critters must suppress it.
        let decorated = IconRenderer.makeIcon(
            primaryRemaining: 60,
            weeklyRemaining: 40,
            creditsRemaining: nil,
            stale: false,
            style: .codex,
            hideCritters: false)
        let plain = IconRenderer.makeIcon(
            primaryRemaining: 60,
            weeklyRemaining: 40,
            creditsRemaining: nil,
            stale: false,
            style: .codex,
            hideCritters: true)

        #expect(try self.pixels(decorated) != self.pixels(plain))
    }

    @Test
    func `hiding critters is a no-op for an undecorated style`() throws {
        // Cursor has no critter twist, so the flag must not alter its bars.
        let withFlag = IconRenderer.makeIcon(
            primaryRemaining: 60,
            weeklyRemaining: 40,
            creditsRemaining: nil,
            stale: false,
            style: .cursor,
            hideCritters: true)
        let withoutFlag = IconRenderer.makeIcon(
            primaryRemaining: 60,
            weeklyRemaining: 40,
            creditsRemaining: nil,
            stale: false,
            style: .cursor,
            hideCritters: false)

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
