import AppKit
import CodexBarCore
import Foundation
import Observation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct MenuBarProviderColorTests {
    private let now = Date(timeIntervalSince1970: 1_752_768_000)

    // MARK: - Settings & Persistence

    @Test
    func `provider color defaults off persists and triggers menu observation`() {
        let defaults = InMemoryUserDefaults()
        let store = testSettingsStore(suiteName: "provider-color", userDefaults: defaults)
        #expect(!store.menuBarColorByProvider)

        let changed = LockIsolated(false)
        withObservationTracking {
            _ = store.menuObservationToken
        } onChange: {
            changed.setValue(true)
        }

        store.menuBarColorByProvider = true
        #expect(changed.value)
        #expect(defaults.bool(forKey: "menuBarColorByProvider"))

        let restored = testSettingsStore(suiteName: "provider-color-restored", userDefaults: defaults)
        #expect(restored.menuBarColorByProvider)
    }

    @Test
    func `portable preferences round trip includes color by provider`() throws {
        let sourceDefaults = InMemoryUserDefaults()
        let source = testSettingsStore(suiteName: "provider-color-source", userDefaults: sourceDefaults)
        source.menuBarColorByProvider = true

        let targetDefaults = InMemoryUserDefaults()
        let target = testSettingsStore(suiteName: "provider-color-target", userDefaults: targetDefaults)
        #expect(!target.menuBarColorByProvider)

        let document = try PreferencesDocument(data: source.exportPreferences().encoded())
        try target.importPreferences(document)
        #expect(target.menuBarColorByProvider)
    }

    // MARK: - Contrast Policy & Relative Luminance

    @Test(arguments: ["aqua", "darkAqua", "NSAppearanceNameVibrantLight", "NSAppearanceNameVibrantDark"])
    func `contrast policy accepts standard provider accents in supported appearances`(appearance: String) {
        for provider in [UsageProvider.claude, .codex, .copilot, .cursor] {
            let options = self.options(appearanceName: appearance, colorByProvider: true)
            let tint = MenuBarLayoutRenderer.effectiveProviderTintColor(for: provider, options: options)
            #expect(tint != nil, "Expected accent for \(provider) to meet contrast in \(appearance)")
        }
    }

    @Test
    func `contrast policy rejects low contrast colors`() {
        // Pure white (#FFFFFF) has 1.0:1 contrast against light background (fails >= 2.0:1)
        let whiteMeetsLight = MenuBarLayoutRenderer.meetsAppearanceContrast(
            accent: ProviderColor(hex: 0xFFFFFF),
            appearanceName: "aqua")
        #expect(!whiteMeetsLight)

        // Pure black (#000000) has 1.0:1 contrast against dark background (fails >= 2.0:1)
        let blackMeetsDark = MenuBarLayoutRenderer.meetsAppearanceContrast(
            accent: ProviderColor(hex: 0x000000),
            appearanceName: "darkAqua")
        #expect(!blackMeetsDark)
    }

    @Test
    func `contrast policy falls back when highlighted stale or under high contrast`() {
        let provider = UsageProvider.claude

        // Highlighted (menu open) must fall back to monochrome
        let highlightedOptions = self.options(isHighlighted: true, colorByProvider: true)
        let highlightedTint = MenuBarLayoutRenderer.effectiveProviderTintColor(
            for: provider,
            options: highlightedOptions)
        #expect(highlightedTint == nil)

        // Stale data must fall back to monochrome
        let staleOptions = self.options(isStale: true, colorByProvider: true)
        let staleTint = MenuBarLayoutRenderer.effectiveProviderTintColor(
            for: provider,
            options: staleOptions)
        #expect(staleTint == nil)

        // High contrast mode must fall back to monochrome
        let highContrastOptions = self.options(colorByProvider: true, highContrast: true)
        let highContrastTint = MenuBarLayoutRenderer.effectiveProviderTintColor(
            for: provider,
            options: highContrastOptions)
        #expect(highContrastTint == nil)
    }

    @Test
    func `gray accent below threshold on the proof background falls back`() {
        // #444444 is 1.551:1 against the existing dark proof background (0.14, 0.15, 0.17).
        #expect(!MenuBarLayoutRenderer.meetsAppearanceContrast(
            accent: ProviderColor(hex: 0x444444),
            appearanceName: "darkAqua"))
        #expect(!MenuBarLayoutRenderer.meetsAppearanceContrast(
            accent: ProviderColor(hex: 0xAAAAAA), appearanceName: "aqua"))
    }

    @Test(arguments: [
        NSAppearance.Name.accessibilityHighContrastAqua.rawValue,
        NSAppearance.Name.accessibilityHighContrastDarkAqua.rawValue,
    ])
    func `accessibility appearances fall back without relying on color`(appearance: String) {
        let options = self.options(appearanceName: appearance, colorByProvider: true)
        #expect(MenuBarLayoutRenderer.effectiveProviderTintColor(for: .claude, options: options) == nil)
    }

    @Test
    func `spoken provider labels do not depend on color including stacked text only rows`() {
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.percent(window: .session)]])
        func stacked(enabled: Bool) -> MenuBarLayoutRenderedTitle {
            let options = self.options(colorByProvider: enabled)
            return MenuBarLayoutRenderer.composeStackedProviderRows(
                top: renderer.render(layout: layout, data: self.data(provider: .claude), icon: nil, options: options),
                bottom: renderer.render(layout: layout, data: self.data(provider: .codex), icon: nil, options: options),
                topProviderName: "Claude",
                bottomProviderName: "Codex")
        }
        let plain = stacked(enabled: false)
        let colored = stacked(enabled: true)
        #expect(colored.accessibilityLabel == plain.accessibilityLabel)
        #expect(colored.accessibilityLabel.contains("Claude"))
        #expect(colored.accessibilityLabel.contains("Codex"))
        #expect(colored.accessibilityLabel.contains("25%"))
    }

    @Test(arguments: MenuBarIconStyle.allCases, [false, true])
    func `provider colors restore immediately across menu tracking for every style`(
        style: MenuBarIconStyle, merged: Bool) throws
    {
        let settings = testSettingsStore(suiteName: "provider-color-menu-lifecycle")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = merged
        settings.selectedMenuProvider = .claude
        settings.menuBarIconStyle = style
        settings.menuBarColorByProvider = true
        settings.menuBarLayout = MenuBarLayout(lines: [[.percent(window: .session)]])
        for provider in UsageProvider.allCases {
            if let metadata = ProviderRegistry.shared.metadata[provider] {
                settings.setProviderEnabled(
                    provider: provider, metadata: metadata, enabled: provider == .claude || provider == .codex)
            }
        }
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store._setSnapshotForTesting(UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: self.now), provider: .claude)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }
        let item = try #require(merged ? controller.statusItem : controller
            .statusItems[UsageProvider.claude.instanceID])
        let button = try #require(item.button)
        button.appearance = NSAppearance(named: .darkAqua)
        func refresh() {
            if merged { controller.applyIcon(phase: nil) } else { controller.applyIcon(for: .claude, phase: nil) }
        }
        func isColored() -> Bool {
            if style == .iconAndPercent {
                guard button.attributedTitle.length > 0 else { return false }
                let color = button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                let accent = ProviderAccentPalette.color(for: .claude)
                return color == NSColor(srgbRed: accent.red, green: accent.green, blue: accent.blue, alpha: 1)
            }
            return button.image?.isTemplate == false
        }
        refresh()
        #expect(isColored())
        let menu = NSMenu()
        if merged {
            controller.mergedMenu = menu
        } else {
            controller.providerMenus[UsageProvider.claude.instanceID] = menu
        }
        // Match production: the session begins before the open-menu dictionary is populated.
        controller.beginMenuTrackingSession(for: menu)
        #expect(!isColored())
        controller.openMenus[ObjectIdentifier(menu)] = menu
        controller.forgetClosedMenu(menu)
        #expect(isColored())
        settings.menuBarHighContrastOnInactiveDisplays = true
        controller.refreshStatusItemContentForColorMode()
        #expect(!isColored())
        settings.menuBarHighContrastOnInactiveDisplays = false
        controller.refreshStatusItemContentForColorMode()
        #expect(isColored())
        settings.menuBarColorByProvider = false
        refresh()
        #expect(!isColored())
    }

    // MARK: - Layout Rendering & Attributed Output

    @Test(arguments: ["aqua", "darkAqua"])
    func `color by provider tints brand icon and percent tokens`(appearance: String) throws {
        let renderer = MenuBarLayoutRenderer()
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        icon.isTemplate = true

        let layout = MenuBarLayout(lines: [[.icon, .percent(window: .session), .percent(window: .weekly)]])
        let data = self.data(provider: .claude)

        // Baseline (colorByProvider: false) -> monochrome template rendering
        let plainOptions = self.options(appearanceName: appearance, colorByProvider: false)
        let plain = renderer.render(layout: layout, data: data, icon: icon, options: plainOptions)
        #expect(plain.leadingIcon != nil)
        #expect(plain.leadingIcon?.isTemplate == true)

        // Opt-in (colorByProvider: true) -> tinted attributed title with attachment icon
        let coloredOptions = self.options(appearanceName: appearance, colorByProvider: true)
        let colored = renderer.render(layout: layout, data: data, icon: icon, options: coloredOptions)
        #expect(colored.leadingIcon == nil)
        #expect(colored.statusImage == nil)

        let expectedAccent = ProviderAccentPalette.color(for: .claude)

        // Verify percent tokens have the accent color applied
        let title = colored.attributedTitle
        let string = title.string
        let sessionRange = (string as NSString).range(of: "25%")
        let weeklyRange = (string as NSString).range(of: "60%")
        try #require(sessionRange.location != NSNotFound)
        try #require(weeklyRange.location != NSNotFound)

        let sessionColor = title.attribute(.foregroundColor, at: sessionRange.location, effectiveRange: nil) as? NSColor
        let weeklyColor = title.attribute(.foregroundColor, at: weeklyRange.location, effectiveRange: nil) as? NSColor
        let expectedColor = NSColor(
            srgbRed: expectedAccent.red,
            green: expectedAccent.green,
            blue: expectedAccent.blue,
            alpha: 1.0)
        #expect(sessionColor == expectedColor)
        #expect(weeklyColor == expectedColor)

        // Button application applies attributed title directly without button image
        let button = NSButton()
        _ = StatusItemController.applyMenuBarLayoutContent(colored, for: button, gap: .regular)
        #expect(button.image == nil)
        #expect(button.attributedTitle.string == colored.attributedTitle.string)
    }

    @Test
    func `color by provider preserves pace colors when both are enabled`() throws {
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.percent(window: .session), .pace(window: .weekly)]])
        let data = self.data(provider: .codex)

        let options = self.options(colorPace: true, colorByProvider: true)
        let output = renderer.render(layout: layout, data: data, icon: nil, options: options)

        let title = output.attributedTitle
        let string = title.string
        let percentRange = (string as NSString).range(of: "25%")
        let paceRange = (string as NSString).range(of: "+11%")
        try #require(percentRange.location != NSNotFound)
        try #require(paceRange.location != NSNotFound)

        let percentColor = title.attribute(.foregroundColor, at: percentRange.location, effectiveRange: nil) as? NSColor
        let paceColor = title.attribute(.foregroundColor, at: paceRange.location, effectiveRange: nil) as? NSColor

        let codexAccent = ProviderAccentPalette.color(for: .codex)
        let expectedCodexColor = NSColor(
            srgbRed: codexAccent.red,
            green: codexAccent.green,
            blue: codexAccent.blue,
            alpha: 1.0)
        #expect(percentColor == expectedCodexColor)
        #expect(paceColor == .systemRed)
    }

    @Test(arguments: [false, true])
    func `provider color leaves disabled and neutral pace tokens monochrome`(colorPace: Bool) throws {
        let rendered = MenuBarLayoutRenderer().render(
            layout: MenuBarLayout(lines: [[.pace(window: .automatic)]]),
            data: self.data(),
            icon: nil,
            options: self.options(colorPace: colorPace, colorByProvider: true))
        let color = try #require(rendered.attributedTitle.attribute(
            .foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        #expect(color == .controlTextColor)
    }

    @Test(arguments: ["aqua", "darkAqua"])
    func `custom accent changes invalidate the cache and borderline colors fall back`(appearance: String) {
        defer { ProviderAccentPalette._test_reset() }
        let renderer = MenuBarLayoutRenderer()
        let options = self.options(appearanceName: appearance, colorByProvider: true)
        let layout = MenuBarLayout(lines: [[.percent(window: .session)]])
        func render(accent: String) -> MenuBarLayoutRenderedTitle {
            ProviderAccentPalette.apply(config: CodexBarConfig(providers: [
                ProviderConfig(id: .claude, accentColor: accent),
            ]))
            return renderer.render(layout: layout, data: self.data(provider: .claude), icon: nil, options: options)
        }
        let before = render(accent: "#CC7C5E")
        let after = render(accent: "#49A3B0")
        #expect(!before.attributedTitle.isEqual(to: after.attributedTitle))
        let fallback = render(accent: appearance == "darkAqua" ? "#444444" : "#AAAAAA")
        #expect(fallback.statusImage?.isTemplate == true)
        #expect(fallback.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            == .controlTextColor)
    }

    @Test
    func `color by provider falls back to monochrome when highlighted or stale`() {
        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.percent(window: .session)]])
        let data = self.data(provider: .claude)

        // Highlighted status item
        let highlightedOptions = self.options(isHighlighted: true, colorByProvider: true)
        let highlighted = renderer.render(layout: layout, data: data, icon: nil, options: highlightedOptions)
        let highlightedColor = highlighted.attributedTitle.attribute(
            .foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(highlightedColor == .controlTextColor)

        // Stale data
        let staleOptions = self.options(isStale: true, colorByProvider: true)
        let stale = renderer.render(layout: layout, data: data, icon: nil, options: staleOptions)
        let staleColor = stale.attributedTitle.attribute(
            .foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(staleColor == .secondaryLabelColor)
    }

    // MARK: - Offscreen Proof PNG Generation

    @Test
    func `render provider color proof PNGs`() throws {
        let dirURL = ProcessInfo.processInfo.environment["CODEXBAR_PROVIDER_COLOR_PROOF_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let dirURL { try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true) }

        let renderer = MenuBarLayoutRenderer()
        let layout = MenuBarLayout(lines: [[.icon, .percent(window: .session), .percent(window: .weekly)]])
        let data = self.data(provider: .claude)
        let icon = ProviderBrandIcon.image(for: .claude)

        struct ProofCase {
            let name: String
            let colorByProvider: Bool
            let isDark: Bool
            let isHighlighted: Bool
            let isStale: Bool
            var highContrast = false
        }

        let cases: [ProofCase] = [
            ProofCase(
                name: "before-setting-off",
                colorByProvider: false,
                isDark: true,
                isHighlighted: false,
                isStale: false),
            ProofCase(
                name: "before-setting-off-light",
                colorByProvider: false,
                isDark: false,
                isHighlighted: false,
                isStale: false),
            ProofCase(
                name: "after-setting-on-high-contrast",
                colorByProvider: true,
                isDark: true,
                isHighlighted: false,
                isStale: false,
                highContrast: true),
            ProofCase(
                name: "after-setting-on-dark",
                colorByProvider: true,
                isDark: true,
                isHighlighted: false,
                isStale: false),
            ProofCase(
                name: "after-setting-on-light",
                colorByProvider: true,
                isDark: false,
                isHighlighted: false,
                isStale: false),
            ProofCase(
                name: "after-setting-on-highlighted",
                colorByProvider: true,
                isDark: true,
                isHighlighted: true,
                isStale: false),
            ProofCase(
                name: "after-setting-on-stale",
                colorByProvider: true,
                isDark: true,
                isHighlighted: false,
                isStale: true),
        ]

        for c in cases {
            let appearanceName = c.isDark ? "darkAqua" : "aqua"
            let options = self.options(
                appearanceName: appearanceName,
                isStale: c.isStale,
                isHighlighted: c.isHighlighted,
                colorByProvider: c.colorByProvider,
                highContrast: c.highContrast)
            let rendered = renderer.render(layout: layout, data: data, icon: icon, options: options)

            let button = NSButton()
            button.isBordered = false
            let width = StatusItemController.applyMenuBarLayoutContent(rendered, for: button, gap: .regular)
            let renderWidth = max(width + 16, 80)
            let height: CGFloat = 24
            button.frame = NSRect(x: 8, y: 0, width: width, height: height)

            let container = NSView(frame: NSRect(x: 0, y: 0, width: renderWidth, height: height))
            let appearance = try #require(NSAppearance(named: c.isDark ? .darkAqua : .aqua))
            container.appearance = appearance
            button.appearance = appearance
            container.addSubview(button)

            let scale: CGFloat = 2.0
            let rep = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(renderWidth * scale),
                pixelsHigh: Int(height * scale),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0))
            rep.size = NSSize(width: renderWidth, height: height)

            appearance.performAsCurrentDrawingAppearance {
                guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = ctx

                let bgColor: NSColor = if c.isHighlighted {
                    .selectedContentBackgroundColor
                } else if c.isDark {
                    NSColor(srgbRed: 0.14, green: 0.15, blue: 0.17, alpha: 1.0)
                } else {
                    NSColor(srgbRed: 0.92, green: 0.93, blue: 0.94, alpha: 1.0)
                }
                bgColor.setFill()
                NSRect(x: 0, y: 0, width: renderWidth, height: height).fill()

                container.displayIgnoringOpacity(container.bounds, in: ctx)
                NSGraphicsContext.restoreGraphicsState()
            }

            let pngData = try #require(rep.representation(using: .png, properties: [:]))
            if let dirURL { try pngData.write(to: dirURL.appendingPathComponent("\(c.name).png")) }
            var warmIconPixels = 0
            var warmTextPixels = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          color.redComponent > color.blueComponent + 0.15 else { continue }
                    if x < 55 { warmIconPixels += 1 } else { warmTextPixels += 1 }
                }
            }
            if c.colorByProvider, !c.isHighlighted, !c.isStale, !c.highContrast {
                #expect(warmIconPixels > 10, "\(c.name): icon must retain rendered provider color")
                #expect(warmTextPixels > 20, "\(c.name): text must retain rendered provider color")
            } else {
                #expect(warmIconPixels + warmTextPixels == 0, "\(c.name): fallback must render monochrome")
            }
        }
    }

    // MARK: - Fixtures & Helpers

    private func data(provider: UsageProvider = .codex) -> MenuBarLayoutRenderData {
        MenuBarLayoutRendererTests().data(provider: provider)
    }

    private func options(
        appearanceName: String = "darkAqua",
        isStale: Bool = false,
        isHighlighted: Bool = false,
        colorPace: Bool = false,
        colorByProvider: Bool = false,
        highContrast: Bool = false) -> MenuBarLayoutRenderOptions
    {
        MenuBarLayoutRenderOptions(
            size: .regular,
            highContrast: highContrast,
            showUsed: true,
            conditionals: [],
            appearanceName: appearanceName,
            isDebugApp: false,
            isStale: isStale,
            isHighlighted: isHighlighted,
            now: self.now,
            verticalAdjustment: 0,
            colorPace: colorPace,
            colorByProvider: colorByProvider,
            forceStackedStyle: false)
    }
}
