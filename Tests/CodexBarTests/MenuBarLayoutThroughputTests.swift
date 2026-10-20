import AppKit
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct MenuBarLayoutThroughputTests {
    @Test
    func `tokens per minute round trips and older projections retain other tokens`() throws {
        let layout = MenuBarLayout(lines: [[.icon, .tokensPerMinute, .tokensSparkline, .costToday]])
        let blobs = try MenuBarLayoutPersistence.encoded(layout)
        let decoder = JSONDecoder()
        #expect(try decoder.decode(MenuBarLayout.self, from: blobs.current) == layout)
        for blob in [blobs.legacy, blobs.released, blobs.v3, blobs.v4] {
            #expect(try decoder.decode(MenuBarLayout.self, from: blob) == .init(lines: [[.icon, .costToday]]))
            let text = try #require(String(data: blob, encoding: .utf8))
            #expect(!text.contains("tokensPerMinute"))
            #expect(!text.contains("tokensSparkline"))
        }
        #expect(MenuBarLayoutPaletteTokens.conditionalBranch.contains(.tokensPerMinute))
        #expect(MenuBarLayoutPaletteTokens.usage(provider: .openai, snapshot: nil).contains(.tokensPerMinute))
        #expect(MenuBarLayoutToken.tokensPerMinute.editorLabel(provider: .openai) == L("Tokens / min"))
        #expect(!MenuBarLayout.defaultLayout.lines.joined().contains(.tokensPerMinute))
        #expect(!MenuBarLayout.defaultLayout.lines.joined().contains(.tokensSparkline))
        #expect(MenuBarLayoutPaletteTokens.conditionalBranch.contains(.tokensSparkline))
        #expect(MenuBarLayoutPaletteTokens.usage(provider: .openai, snapshot: nil).contains(.tokensSparkline))
        #expect(MenuBarLayoutToken.tokensSparkline.editorLabel(provider: .openai) == L("Tokens / min graph"))
    }

    @Test
    func `the v4 generation stays readable and the newer layout and rules win on load`() throws {
        let decoder = JSONDecoder()
        let layout = MenuBarLayout(lines: [[.icon, .tokensPerMinute, .tokensSparkline, .costToday]])
        let blobs = try MenuBarLayoutPersistence.encoded(layout)
        let restored = try MenuBarLayoutPersistence.preferredLayout(
            current: decoder.decode(MenuBarLayout.self, from: blobs.current),
            v4: decoder.decode(MenuBarLayout.self, from: blobs.v4),
            v3: decoder.decode(MenuBarLayout.self, from: blobs.v3),
            released: decoder.decode(MenuBarLayout.self, from: blobs.released),
            legacy: decoder.decode(MenuBarLayout.self, from: blobs.legacy))
        #expect(restored == layout)

        var library = MenuBarLayoutConditional.shippedLibrary()
        library[0].thenToken = .tokensPerMinute
        library[0].elseToken = .tokensSparkline
        let rules = try MenuBarLayoutPersistence.encodedLibrary(library)
        let v4Text = try #require(String(data: rules.v4, encoding: .utf8))
        #expect(!v4Text.contains("tokensPerMinute"))
        #expect(!v4Text.contains("tokensSparkline"))
        let v4Rules = try decoder.decode([MenuBarLayoutConditional].self, from: rules.v4)
        #expect(v4Rules[0].thenToken == .hidden)
        #expect(v4Rules[0].elseToken == .hidden)
        let restoredRules = try MenuBarLayoutPersistence.preferredLibrary(
            current: decoder.decode([MenuBarLayoutConditional].self, from: rules.current),
            v5: decoder.decode([MenuBarLayoutConditional].self, from: rules.v5),
            v4: v4Rules,
            v3: decoder.decode([MenuBarLayoutConditional].self, from: rules.v3),
            released: decoder.decode([MenuBarLayoutConditional].self, from: rules.released),
            legacy: decoder.decode([MenuBarLayoutConditional].self, from: rules.legacy))
        #expect(restoredRules == library)
    }

    @Test
    func `tokens per minute renders compact value and standard missing value`() {
        let fixture = MenuBarLayoutRendererTests()
        var data = fixture.data(provider: .openai)
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.tokensPerMinute]])
        let missing = renderer.render(layout: layout, data: data, icon: nil, options: fixture.options())
        #expect(missing.attributedTitle.string == "–")
        data.tokensPerMinute = 49_000_000
        let actual = renderer.render(layout: layout, data: data, icon: nil, options: fixture.options())
        #expect(actual.attributedTitle.string == "49M/min")
        data.tokensPerMinute = 0
        #expect(renderer.render(layout: layout, data: data, icon: nil, options: fixture.options())
            .attributedTitle.string == "0/min")
    }

    @Test
    func `sparkline buckets preserve peaks and stop at the reporting frontier`() {
        let minutes = (0..<60).map { index in
            ProviderThroughputSnapshot.Minute(
                start: Date(timeIntervalSince1970: Double(index * 60)),
                totalTokens: index == 41 ? 151_000_000 : index == 56 ? 49_000_000 : index * 1_000_000,
                requests: 50,
                isPending: index >= 57)
        }
        let graph = MenuBarTokensSparkline(minutes: minutes)
        #expect(graph.values.count == 18)
        #expect(graph.values.max() == 151_000_000)
        #expect(graph.latest == 49_000_000)
        #expect(graph.values.first == 2_000_000)
        #expect(graph.values.last == 55_000_000)
        #expect(graph == MenuBarTokensSparkline(minutes: Array(minutes.prefix(57))))
        #expect(MenuBarTokensSparkline(minutes: Array(minutes.suffix(3))).values.isEmpty)
        #expect(MenuBarTokensSparkline(minutes: []).values.isEmpty)
        let single = MenuBarTokensSparkline(minutes: Array(minutes.prefix(1)))
        #expect(single.values == [0])
        #expect(single.latest == 0)
        #expect(MenuBarTokensSparkline(minutes: minutes, columnCount: 0).values == [151_000_000])
    }

    @Test
    func `sparkline renders a template attachment with no extra gap for unavailable data`() throws {
        let fixture = MenuBarLayoutRendererTests()
        var data = fixture.data(provider: .openai)
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.tokensPerMinute, .tokensSparkline]])
        let missing = renderer.render(layout: layout, data: data, icon: nil, options: fixture.options())
        #expect(missing.attributedTitle.string == "–\u{2009}–")
        data.tokensSparkline = .init(values: [], latest: nil)
        #expect(renderer.render(
            layout: .init(lines: [[.tokensSparkline]]),
            data: data,
            icon: nil,
            options: fixture.options()).attributedTitle.string == "–")
        data.tokensPerMinute = 49_000_000
        data.tokensSparkline = .init(values: [0, 49_000_000, 151_000_000], latest: 49_000_000)
        for dark in [false, true] {
            let options = fixture.options(appearanceName: dark ? "NSAppearanceNameDarkAqua" : "NSAppearanceNameAqua")
            let output = renderer.render(layout: layout, data: data, icon: nil, options: options)
            #expect(output.accessibilityLabel.contains(L("Tokens per minute, latest %@", "49M")))
            let index = output.attributedTitle.length - 1
            let attachment = try #require(output.attributedTitle.attribute(
                .attachment,
                at: index,
                effectiveRange: nil) as? NSTextAttachment)
            #expect(attachment.image?.isTemplate == true)
            #expect(attachment.bounds.width == 34)
            #expect(attachment.bounds.height == 18)
        }
        let first = renderer.render(layout: layout, data: data, icon: nil, options: fixture.options())
        data.tokensSparkline = .init(values: [49_000_000, 0, 151_000_000], latest: 49_000_000)
        let changed = renderer.render(layout: layout, data: data, icon: nil, options: fixture.options())
        #expect(first.attributedTitle !== changed.attributedTitle)
        #expect(data.tokensSparkline?.image(height: 18, highlighted: true)?.isTemplate == true)
    }
}
