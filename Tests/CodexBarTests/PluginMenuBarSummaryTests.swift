import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

func pluginSummarySnapshot(
    claudeUsed: Double = 25, codexUsed: Double = 100, items: [ProviderMenuBarItem]? = nil) throws -> UsageSnapshot
{
    let items = try items ?? [
        ProviderMenuBarItem(title: "Claude", iconProvider: .claude, windowID: "claude"),
        ProviderMenuBarItem(title: "Codex", iconProvider: .codex, windowID: "codex"),
        ProviderMenuBarItem(title: "z.ai", iconProvider: .zai, windowID: "absent"),
    ]
    return UsageSnapshot(
        primary: nil,
        secondary: nil,
        extraRateWindows: [
            NamedRateWindow(id: "claude", title: "Claude", window: RateWindow(
                usedPercent: claudeUsed, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
            NamedRateWindow(id: "codex", title: "Codex", window: RateWindow(
                usedPercent: codexUsed, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
        ],
        menuBarItems: items,
        updatedAt: Date(timeIntervalSince1970: 0))
}

@MainActor
struct PluginMenuBarSummaryTests {
    @Test
    func `summary keeps item ownership order zero and unavailable values`() throws {
        let snapshot = try pluginSummarySnapshot()
        let remaining = PluginMenuBarSummaryRenderer.elements(snapshot: snapshot, showUsed: false)
        #expect(remaining.map(\.iconProvider) == [.claude, .codex, .zai])
        #expect(remaining.map(\.value) == [UsageFormatter.percentString(75), UsageFormatter.percentString(0), "—"])
        let used = PluginMenuBarSummaryRenderer.elements(snapshot: snapshot, showUsed: true)
        #expect(used.map(\.value) == [UsageFormatter.percentString(25), UsageFormatter.percentString(100), "—"])
    }

    @Test
    func `summary caches unchanged frames and never resizes shared provider icons`() throws {
        let renderer = PluginMenuBarSummaryRenderer()
        let elements = try PluginMenuBarSummaryRenderer.elements(snapshot: pluginSummarySnapshot(), showUsed: false)
        let brand = try #require(ProviderBrandIcon.image(for: .claude))
        let size = brand.size
        func render(_ elements: [PluginMenuBarSummaryRenderer.Element], highContrast: Bool = false)
            -> MenuBarLayoutRenderedTitle
        {
            let options = PluginMenuBarSummaryRenderer.Options(
                sourceHash: "fixture",
                monospaced: true,
                highContrast: highContrast,
                appearance: NSAppearance.Name.aqua.rawValue)
            return renderer.render(elements: elements, options: options) {
                Issue.record("Bundled provider icons should be available")
                return NSImage()
            }
        }
        let first = render(elements)
        let cached = render(elements)
        #expect(first.attributedTitle === cached.attributedTitle)
        #expect(first.statusImage?.isTemplate == true)
        #expect(brand.size == size)
        #expect(first.accessibilityLabel.contains("Claude"))
        #expect(first.accessibilityLabel.contains("Codex"))
        let reordered = render(Array(elements.reversed()))
        #expect(reordered.attributedTitle !== cached.attributedTitle)
        #expect(reordered.accessibilityLabel.hasPrefix("z.ai"))
        let contrast = render(elements, highContrast: true)
        #expect(contrast.statusImage == nil)
        #expect(contrast.attributedTitle.length > 0)
    }
}
