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
    func `fill width tracks and clamps the reported percentage`() {
        #expect(IconRenderer.fillWidthPixels(remaining: 46, rectWidth: 30) == 14)
        #expect(IconRenderer.fillWidthPixels(remaining: -1, rectWidth: 30) == 0)
        #expect(IconRenderer.fillWidthPixels(remaining: 0, rectWidth: 30) == 0)
        #expect(IconRenderer.fillWidthPixels(remaining: 100, rectWidth: 30) == 30)
        #expect(IconRenderer.fillWidthPixels(remaining: 120, rectWidth: 30) == 30)
    }

    @Test
    func `single quota layout follows provider policy even in combined style`() throws {
        func image(
            primary: Double?,
            weekly: Double?,
            policy: IconRenderer.QuotaLayoutPolicy) -> NSImage
        {
            IconRenderer.makeIcon(
                primaryRemaining: primary,
                weeklyRemaining: weekly,
                creditsRemaining: nil,
                stale: false,
                style: .combined,
                hideCritters: true,
                quotaLayoutPolicy: policy)
        }

        let compact = IconRenderer.QuotaLayoutPolicy.provider(.codex)
        let reserved = IconRenderer.QuotaLayoutPolicy.provider(.claude)
        let compactPrimary = image(primary: 46, weekly: nil, policy: compact)
        let compactSecondary = image(primary: nil, weekly: 46, policy: compact)
        let reservedPrimary = image(primary: 46, weekly: nil, policy: reserved)

        #expect(try self.pixels(compactPrimary) == self.pixels(compactSecondary))
        #expect(try self.pixels(compactPrimary) != self.pixels(reservedPrimary))
    }

    @Test
    func `special and multi-value layouts remain unchanged`() throws {
        func image(
            primary: Double?,
            weekly: Double?,
            credits: Double? = nil,
            policy: IconRenderer.QuotaLayoutPolicy) -> NSImage
        {
            IconRenderer.makeIcon(
                primaryRemaining: primary,
                weeklyRemaining: weekly,
                creditsRemaining: credits,
                stale: false,
                style: .combined,
                hideCritters: true,
                quotaLayoutPolicy: policy)
        }

        let compact = IconRenderer.QuotaLayoutPolicy.provider(.codex)
        let reserved = IconRenderer.QuotaLayoutPolicy.provider(.claude)
        let warp = IconRenderer.QuotaLayoutPolicy.provider(.warp)

        #expect(try self.pixels(image(primary: 46, weekly: 46, policy: compact))
            == self.pixels(image(primary: 46, weekly: 46, policy: reserved)))
        #expect(try self.pixels(image(primary: 46, weekly: 0, policy: compact))
            == self.pixels(image(primary: 46, weekly: 0, policy: reserved)))
        #expect(try self.pixels(image(primary: nil, weekly: nil, credits: 460, policy: compact))
            == self.pixels(image(primary: nil, weekly: nil, credits: 460, policy: reserved)))
        #expect(try self.pixels(image(primary: 46, weekly: nil, policy: warp))
            == self.pixels(image(primary: 46, weekly: 0, policy: warp)))

        let unknown = image(primary: nil, weekly: nil, policy: compact)
        #expect(try self.pixels(unknown).isEmpty == false)
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
