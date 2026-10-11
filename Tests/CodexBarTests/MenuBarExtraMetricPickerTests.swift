import AppKit
import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

struct MenuBarExtraMetricPickerTests {
    @Test
    @MainActor
    func `synthetic named metric presentation proof`() throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_GROK_METRIC_PROOF_DIR"] else { return }
        let fixture = MenuBarLayoutRendererTests()
        let image = NSImage(size: NSSize(width: 720, height: 220))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 720, height: 220).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black,
        ]
        ("Cursor menu bar · Synthetic data" as NSString).draw(
            at: NSPoint(x: 20, y: 185), withAttributes: attributes)
        let choices = MenuBarPercentWindowPreference.available(for: .cursor).map { $0.label(for: .cursor) }
        ("Metric choices: " + choices.joined(separator: " · ") as NSString).draw(
            at: NSPoint(x: 20, y: 150), withAttributes: attributes)
        for (index, known) in [true, false].enumerated() {
            let extras = known ? [MenuBarLayoutRenderExtra(NamedRateWindow(
                id: "cursor-grok-bot",
                title: "Grok Bot",
                window: RateWindow(usedPercent: 42, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)))] : []
            let rendered = MenuBarLayoutRenderer().render(
                layout: MenuBarLayout(lines: [[.extraPercent(id: "cursor-grok-bot")]]),
                data: fixture.data(provider: .cursor, extraRateWindows: extras),
                icon: nil,
                options: fixture.options())
            let y = CGFloat(95 - index * 45)
            (known ? "Known reading:" : "Missing reading:" as NSString).draw(
                at: NSPoint(x: 20, y: y), withAttributes: attributes)
            let text = NSMutableAttributedString(attributedString: rendered.attributedTitle)
            text.addAttributes(attributes, range: NSRange(location: 0, length: text.length))
            text.draw(at: NSPoint(x: 185, y: y))
        }
        image.unlockFocus()
        let bitmap = try NSBitmapImageRep(data: #require(image.tiffRepresentation))
        let png = try #require(bitmap?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("grok-metric.png"))
    }

    @Test
    func `metric table offers each provider owned named allowance before fetching`() {
        for descriptor in ProviderDescriptorRegistry.all {
            let labels = MenuBarPercentWindowPreference.available(for: descriptor.id)
                .map { $0.label(for: descriptor.id) }
            for title in descriptor.menuBarMetrics.namedExtras.values {
                #expect(labels.contains(title))
            }
        }
        #expect(!MenuBarPercentWindowPreference.available(for: .codex)
            .map { $0.label(for: .codex) }.contains("Grok Bot"))
        #expect(MenuBarPercentWindowPreference.available(for: .grok)
            .map { $0.label(for: .grok) }.contains("Grok Bot"))
    }

    @Test
    @MainActor
    func `extra choice persists a provider override and switches back without changing balance or resets`() throws {
        let defaults = InMemoryUserDefaults()
        let config = testConfigStore(suiteName: "extra-metric-picker-\(UUID().uuidString)")
        let settings = MenuBarPercentWindowNativeProofTests.settings(defaults: defaults, config: config)
        defer { settings.configFileWatcher?.stop() }
        settings.menuBarIconStyle = .iconAndPercent
        let original = MenuBarLayout(lines: [[
            .icon, .percent(window: .automatic), .balance, .windowResetCountdown(window: .weekly),
        ]])
        settings.setMenuBarLayout(original, for: nil)
        let view = ProviderMenuBarPercentWindowSettingsView(provider: .cursor, settings: settings)
        let picker = ProviderMenuBarPercentWindowPicker(
            provider: .cursor, iconStyle: .iconAndPercent, layout: view.layoutBinding)
        let extra = try #require(MenuBarPercentWindowPreference.available(for: .cursor)
            .first { $0.label(for: .cursor) == "Grok Bot" })
        picker.selectionBinding.wrappedValue = extra
        let expected = MenuBarLayout(lines: [[
            .icon, .extraPercent(id: "cursor-grok-bot"), .balance, .windowResetCountdown(window: .weekly),
        ]])
        #expect(settings.menuBarLayoutResolution(for: .cursor).layout == expected)
        #expect(settings.menuBarLayoutResolution(for: .claude).layout == original)
        #expect(picker.selectionBinding.wrappedValue == extra)
        #expect(MenuBarPercentWindowPreference.isVisible(
            iconStyle: .iconAndPercent, layout: expected, provider: .cursor))
        let reloaded = MenuBarPercentWindowNativeProofTests.settings(defaults: defaults, config: config)
        defer { reloaded.configFileWatcher?.stop() }
        #expect(reloaded.menuBarLayoutResolution(for: .cursor).layout == expected)
        picker.selectionBinding.wrappedValue = .automatic
        #expect(settings.menuBarLayoutResolution(for: .cursor).layout == original)
    }

    @Test
    func `independent extra tokens survive ordinary metric edits without being duplicated`() throws {
        let extra = try #require(MenuBarPercentWindowPreference.available(for: .cursor)
            .first { $0.label(for: .cursor) == "Grok Bot" })
        let layout = MenuBarLayout(lines: [[.percent(window: .session), .extraPercent(id: "cursor-grok-bot")]])
        #expect(MenuBarPercentWindowPreference.current(in: layout) == .session)
        #expect(!MenuBarPercentWindowPreference.available(for: .cursor, layout: layout).contains(extra))
        #expect(extra.applied(to: layout) == layout)
        #expect(MenuBarPercentWindowPreference.weekly.applied(to: layout).lines == [[
            .percent(window: .weekly), .extraPercent(id: "cursor-grok-bot"),
        ]])
    }

    @Test
    func `extra choices cannot take ownership of independently placed metrics`() {
        let cases: [(UsageProvider, MenuBarLayoutToken, MenuBarPercentWindowPreference)] = [
            (.cursor, .lanePercent(lane: .tertiary), .extra(id: "cursor-grok-bot")),
            (
                .antigravity,
                .extraPercent(id: "antigravity-quota-summary-gemini-weekly"),
                .extra(id: "antigravity-quota-summary-3p-weekly")),
        ]
        for (provider, independent, extra) in cases {
            let layout = MenuBarLayout(lines: [[.percent(window: .automatic), independent]])
            #expect(!MenuBarPercentWindowPreference.available(for: provider, layout: layout).contains(extra))
            #expect(extra.applied(to: layout) == layout)
        }
    }

    @Test
    func `multiple independent extras remain under layout editor control`() {
        let layout = MenuBarLayout(lines: [[
            .extraPercent(id: "antigravity-quota-summary-gemini-weekly"),
            .extraPercent(id: "antigravity-quota-summary-3p-weekly"),
        ]])
        #expect(MenuBarPercentWindowPreference.current(in: layout) == nil)
        #expect(MenuBarPercentWindowPreference.available(for: .antigravity, layout: layout).isEmpty)
        #expect(MenuBarPercentWindowPreference.automatic.applied(to: layout) == layout)
    }
}
