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
        .grok,
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
        .grok,
    ])
    func `hidden decorated styles match plain capsule bars`(style: IconStyle) throws {
        let hidden = self.icon(style: style, hideCritters: true)
        let reference = self.icon(style: .cursor, hideCritters: true)

        #expect(try self.pixels(hidden) == self.pixels(reference))
    }

    @Test(arguments: [true, false])
    func `Grok visor decorates either single quota and respects Hide Critters`(primary: Bool) throws {
        func render(hidden: Bool, style: IconStyle) -> NSImage {
            IconRenderer.makeIcon(
                primaryRemaining: primary ? 60 : nil,
                weeklyRemaining: primary ? nil : 60,
                creditsRemaining: nil,
                stale: false,
                style: style,
                hideCritters: hidden)
        }
        #expect(try self.pixels(render(hidden: false, style: .grok)) != self.pixels(render(hidden: true, style: .grok)))
        #expect(try self.pixels(render(hidden: true, style: .grok)) == self.pixels(render(
            hidden: true,
            style: .cursor)))
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

    @Test
    func `credits fill distinguishes balances above the historical 1k cap`() throws {
        func image(credits: Double) -> NSImage {
            IconRenderer.makeIcon(
                primaryRemaining: nil,
                weeklyRemaining: nil,
                creditsRemaining: credits,
                stale: false,
                style: .combined,
                hideCritters: true)
        }

        try CreditsBarScale.$highWater.withValue(CreditsBarScale.HighWater()) {
            // Independent snapshots: 50% of 1000 vs 100% of 1000 → 15px vs 30px in a 30px bar.
            #expect(try self.pixels(image(credits: 500)) != self.pixels(image(credits: 1000)))
        }
        try CreditsBarScale.$highWater.withValue(CreditsBarScale.HighWater()) {
            // 2263/3000 ≈ 75.4% → 23px; 1000/1000 = 100% → 30px.
            #expect(try self.pixels(image(credits: 2263)) != self.pixels(image(credits: 1000)))
        }
        try CreditsBarScale.$highWater.withValue(CreditsBarScale.HighWater()) {
            // Same 2000 auto bucket, clearly different pixel widths: 1200 → 60% → 18px; 1800 → 90% → 27px.
            // 2263 vs 1500 both occupy ~23px (75.4% of 3000 vs 75% of 2000) and must not be used here.
            #expect(try self.pixels(image(credits: 1200)) != self.pixels(image(credits: 1800)))
        }
    }

    @Test
    func `credits fill does not refill across a thousand-credit bucket boundary`() throws {
        func image(credits: Double) -> NSImage {
            IconRenderer.makeIcon(
                primaryRemaining: nil,
                weeklyRemaining: nil,
                creditsRemaining: credits,
                stale: false,
                style: .combined,
                hideCritters: true)
        }

        try CreditsBarScale.$highWater.withValue(CreditsBarScale.HighWater()) {
            // 2500/3000 ≈ 83.3% → 25px, then 2000/3000 ≈ 66.7% → 20px. Stateless auto would refill 2000 to 30px.
            let afterHigh = image(credits: 2500)
            let afterSpend = image(credits: 2000)
            #expect(try self.pixels(afterHigh) != self.pixels(afterSpend))

            try CreditsBarScale.$highWater.withValue(CreditsBarScale.HighWater()) {
                let independentBoundary = image(credits: 2000)
                #expect(try self.pixels(afterSpend) != self.pixels(independentBoundary))
            }
        }
    }

    @Test
    func `credits fill isolates auto scale when switching Codex accounts`() throws {
        let store = CreditsBarScale.HighWater()
        let accountA = CreditsBarScale.Account(accountID: "acct-a", email: "a@example.com")
        let accountB = CreditsBarScale.Account(accountID: "acct-b", email: "b@example.com")

        func image(credits: Double, account: CreditsBarScale.Account) -> NSImage {
            IconRenderer.makeIcon(
                primaryRemaining: nil,
                weeklyRemaining: nil,
                creditsRemaining: credits,
                stale: false,
                style: .combined,
                hideCritters: true,
                creditsAccount: account)
        }

        try CreditsBarScale.$highWater.withValue(store) {
            _ = image(credits: 2500, account: accountA)
            store.invalidateSelection(from: accountA, to: accountB)
            let switched = image(credits: 500, account: accountB)
            try CreditsBarScale.$highWater.withValue(CreditsBarScale.HighWater()) {
                let independent = image(credits: 500, account: accountB)
                #expect(try self.pixels(switched) == self.pixels(independent))
            }
            try CreditsBarScale.$highWater.withValue(CreditsBarScale.HighWater()) {
                let contaminated = image(credits: 500, account: accountA)
                #expect(try self.pixels(switched) != self.pixels(contaminated))
            }
        }
    }
}
