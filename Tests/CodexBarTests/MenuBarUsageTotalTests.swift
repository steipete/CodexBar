import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct MenuBarUsageTotalTests {
    private typealias Entry = MenuBarUsageTotal.Entry

    private static func options(
        showUsed: Bool = false,
        highContrast: Bool = false,
        verticalAdjustment: Int = 0) -> MenuBarLayoutRenderOptions
    {
        MenuBarLayoutRenderOptions(
            size: .regular,
            highContrast: highContrast,
            showUsed: showUsed,
            conditionals: [],
            appearanceName: NSAppearance.Name.darkAqua.rawValue,
            isDebugApp: false,
            isStale: false,
            now: Date(),
            verticalAdjustment: verticalAdjustment)
    }

    private static func window(used: Double) -> RateWindow {
        RateWindow(usedPercent: used, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
    }

    private static func snapshot(used: Double, weeklyUsed: Double? = nil) -> UsageSnapshot {
        UsageSnapshot(
            primary: self.window(used: used),
            secondary: weeklyUsed.map {
                RateWindow(usedPercent: $0, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)
            },
            updatedAt: Date())
    }

    private static func data(
        session: Double?,
        weekly: Double? = nil,
        scoped: Double? = nil,
        automatic: Double? = nil,
        automaticText: String? = nil) -> MenuBarLayoutRenderData
    {
        let render = { (used: Double?) in used.flatMap { MenuBarLayoutRenderWindow(Self.window(used: $0)) } }
        return MenuBarLayoutRenderData(
            provider: UsageProvider.claude.instanceID,
            iconKey: UsageProvider.claude.rawValue,
            providerName: "Claude",
            accountLabel: nil,
            laneLabels: MenuBarLayoutLaneLabels(provider: .claude, snapshot: nil),
            primary: render(session),
            secondary: render(weekly),
            tertiary: nil,
            session: render(session),
            weekly: render(weekly),
            scopedWeekly: render(scoped),
            scopedWeeklyTitle: nil,
            automatic: render(automatic),
            automaticText: automaticText,
            sessionPace: nil,
            weeklyPace: nil,
            automaticPace: nil,
            runsOut: nil,
            balance: nil,
            costToday: nil,
            cost30d: nil,
            metrics: MenuBarLayoutRenderMetrics(
                sessionPaceDelta: nil,
                weeklyPaceDelta: nil,
                automaticPaceDelta: nil,
                runsOutMinutes: nil,
                balanceRemainingUSD: nil,
                balanceUsedUSD: nil,
                costTodayUSD: nil,
                cost30dUSD: nil))
    }

    // MARK: - The reading

    @Test
    func `total averages each provider and keeps no reading without quotas`() throws {
        #expect(MenuBarUsageTotal(entries: []) == nil)
        let total = try #require(MenuBarUsageTotal(entries: [
            Entry(provider: .claude, remainingPercent: 80, isStale: false),
            Entry(provider: .codex, remainingPercent: 40, isStale: false),
        ]))
        #expect(total.averageRemainingPercent == 60)
        #expect(total.providerCount == 2)
        #expect(total.nearLimit.isEmpty)
    }

    @Test
    func `near limit starts at ten percent left with the tightest provider first`() throws {
        let total = try #require(MenuBarUsageTotal(entries: [
            Entry(provider: .cursor, remainingPercent: 10.5, isStale: false),
            Entry(provider: .codex, remainingPercent: 10, isStale: false),
            Entry(provider: .gemini, remainingPercent: 4, isStale: false),
            Entry(provider: .claude, remainingPercent: 4, isStale: false),
        ]))
        // Equal limits keep the user's provider order, so the warning does not flip between refreshes.
        #expect(total.nearLimit.map(\.provider) == [.gemini, .claude, .codex])
    }

    @Test
    func `a forecast within the hour warns like the dropdown does`() throws {
        let total = try #require(MenuBarUsageTotal(entries: [
            Entry(provider: .claude, remainingPercent: 40, isStale: false, runsOutMinutes: 45),
            Entry(provider: .cursor, remainingPercent: 40, isStale: false, runsOutMinutes: 61),
            Entry(provider: .codex, remainingPercent: 5, isStale: false),
            Entry(provider: .gemini, remainingPercent: 40, isStale: true, runsOutMinutes: 5),
        ]))
        // Limits left low come first; a forecast only says when one will get there.
        #expect(total.nearLimit.map(\.provider) == [.codex, .claude])
    }

    @Test
    func `stale data never raises the warning but still counts toward the total`() throws {
        let total = try #require(MenuBarUsageTotal(entries: [
            Entry(provider: .claude, remainingPercent: 2, isStale: true),
            Entry(provider: .codex, remainingPercent: 60, isStale: false),
        ]))
        #expect(total.nearLimit.isEmpty)
        #expect(total.averageRemainingPercent == 31)
        #expect(!total.isStale)

        let allStale = try #require(MenuBarUsageTotal(entries: [
            Entry(provider: .claude, remainingPercent: 2, isStale: true),
        ]))
        #expect(allStale.isStale)
    }

    @Test
    func `a provider reads as its tightest limit`() {
        #expect(MenuBarUsageTotal.tightestRemainingPercent(data: Self.data(session: 20, weekly: 70)) == 30)
        #expect(MenuBarUsageTotal.tightestRemainingPercent(data: Self.data(session: 20, weekly: 30, scoped: 95)) == 5)
        #expect(MenuBarUsageTotal.tightestRemainingPercent(data: Self.data(session: nil, automatic: 25)) == 75)
    }

    @Test
    func `a measured quota outside the semantic lanes can still be the tightest`() {
        // Cursor-shaped: Auto is the weekly lane while Total only exists as a raw window.
        let data = Self.data(session: nil, weekly: 30)
        let total = Self.window(used: 95)
        #expect(MenuBarUsageTotal.tightestRemainingPercent(data: data) == 70)
        #expect(MenuBarUsageTotal.tightestRemainingPercent(data: data, measured: [total]) == 5)

        let balance = Self.data(session: nil, automatic: 99, automaticText: "$4.20")
        #expect(MenuBarUsageTotal.tightestRemainingPercent(data: balance, measured: []) == nil)
    }

    @Test
    func `balance backed lanes are not quotas`() {
        // Their automatic percent is meaningless, which is why the existing bar token refuses to draw it.
        let balance = Self.data(session: nil, automatic: 99, automaticText: "$4.20")
        #expect(MenuBarUsageTotal.tightestRemainingPercent(data: balance) == nil)
        #expect(MenuBarUsageTotal.tightestRemainingPercent(data: Self.data(session: nil)) == nil)
    }

    // MARK: - Rendering

    @Test(arguments: [false, true], [false, true])
    func `saved vertical adjustment shifts and clips every total attachment image`(
        highContrast: Bool, warning: Bool) throws
    {
        let total = try #require(MenuBarUsageTotal(entries: [
            Entry(provider: .claude, remainingPercent: warning ? 8 : 62, isStale: false),
        ]))
        let logo = try #require(ProviderBrandIcon.image(for: .claude))
        let original = MenuBarLayoutRenderer.renderUsageTotal(
            total, logo: logo, options: Self.options(highContrast: highContrast))
        let originalImages = Self.attachmentImages(original.attributedTitle)
        #expect(originalImages.count == (highContrast ? 1 : 0) + (warning ? 1 : 0))
        if !highContrast, !warning {
            #expect(originalImages.isEmpty)
            #expect(original.leadingIcon?.isTemplate == true)
        }
        for scale in [1, 2] {
            for adjustment in [-20, -5, -3, 3, 5, 20] {
                let shifted = MenuBarLayoutRenderer.renderUsageTotal(
                    total,
                    logo: logo,
                    options: Self.options(highContrast: highContrast, verticalAdjustment: adjustment))
                let shiftedImages = Self.attachmentImages(shifted.attributedTitle)
                #expect(shiftedImages.count == originalImages.count)
                let pixelShift = try Self.calibratedPixelShift(adjustment: adjustment, scale: scale)
                for (before, after) in zip(originalImages, shiftedImages) {
                    let originalBitmap = try Self.leadingBitmap(before, scale: scale)
                    let shiftedBitmap = try Self.leadingBitmap(after, scale: scale)
                    Self.expectTranslatedMask(
                        original: originalBitmap,
                        shifted: shiftedBitmap,
                        pixelShift: pixelShift,
                        redOnly: false)
                }
                #expect(shifted.statusItemWidth(gap: .regular) == original.statusItemWidth(gap: .regular))
                #expect(shifted.accessibilityLabel == original.accessibilityLabel)
            }
        }
    }

    private static func attachmentImages(_ title: NSAttributedString) -> [NSImage] {
        var images: [NSImage] = []
        title.enumerateAttribute(.attachment, in: NSRange(location: 0, length: title.length)) { value, _, _ in
            if let image = (value as? NSTextAttachment)?.image { images.append(image) }
        }
        return images
    }

    @Test
    func `calm total is one template image so AppKit tints it for any menu bar`() throws {
        let total = try #require(MenuBarUsageTotal(entries: [
            Entry(provider: .claude, remainingPercent: 62, isStale: false),
        ]))
        let rendered = MenuBarLayoutRenderer.renderUsageTotal(total, logo: nil, options: Self.options())
        let image = try #require(rendered.leadingIcon)
        #expect(image.isTemplate)
        #expect(rendered.attributedTitle.length == 0)
        #expect(rendered.accessibilityLabel.contains("62%"))
    }

    @Test
    func `warning names the provider with its logo and a capsule that ignores the wallpaper`() throws {
        let total = try #require(MenuBarUsageTotal(entries: [
            Entry(provider: .claude, remainingPercent: 8, isStale: false),
            Entry(provider: .codex, remainingPercent: 90, isStale: false),
        ]))
        let logo = try #require(ProviderBrandIcon.image(for: .claude))
        let calm = try #require(MenuBarUsageTotal(entries: [
            Entry(provider: .claude, remainingPercent: 88, isStale: false),
        ]))
        let calmImage = try #require(MenuBarLayoutRenderer.renderUsageTotal(calm, logo: nil, options: Self.options())
            .leadingIcon)

        let rendered = MenuBarLayoutRenderer.renderUsageTotal(total, logo: logo, options: Self.options())
        // Meter and logo stay a native template; only the warning capsule carries its own colour.
        let neutral = try #require(rendered.leadingIcon)
        #expect(neutral.isTemplate)
        let attachment = try #require(rendered.attributedTitle.attribute(
            .attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        let capsule = try #require(attachment.image)
        #expect(!capsule.isTemplate)
        #expect(rendered.accessibilityLabel.contains("Claude"))
        #expect(rendered.accessibilityLabel.contains("8%"))
        #expect(rendered.accessibilityLabel.contains("49%"))
        // The warning stays compact: it trades the total's digits for a logo and the capsule.
        #expect(rendered.statusItemWidth(gap: .regular) - calmImage.size.width <= 40)
    }

    @Test
    func `warning without a logo still names the provider`() throws {
        let total = try #require(MenuBarUsageTotal(entries: [
            Entry(provider: .claude, remainingPercent: 3, isStale: false),
        ]))
        let rendered = MenuBarLayoutRenderer.renderUsageTotal(total, logo: nil, options: Self.options())
        #expect(rendered.accessibilityLabel.contains("Claude"))
        #expect(rendered.attributedTitle.length > 0)
    }

    @Test
    func `show used follows the setting everywhere`() throws {
        let total = try #require(MenuBarUsageTotal(entries: [
            Entry(provider: .claude, remainingPercent: 8, isStale: false),
            Entry(provider: .codex, remainingPercent: 90, isStale: false),
        ]))
        let rendered = MenuBarLayoutRenderer.renderUsageTotal(
            total,
            logo: nil,
            options: Self.options(showUsed: true))
        #expect(rendered.accessibilityLabel.contains("92%"))
        #expect(rendered.accessibilityLabel.contains("51%"))
    }

    @Test
    func `no quota reading renders a placeholder rather than an empty item`() throws {
        let rendered = MenuBarLayoutRenderer.renderUsageTotal(nil, logo: nil, options: Self.options())
        let image = try #require(rendered.leadingIcon)
        #expect(image.isTemplate)
        #expect(!rendered.accessibilityLabel.isEmpty)
    }

    // MARK: - Status item

    @Test
    func `all providers source drives the merged status item and leaves other sources alone`() throws {
        let settings = testSettingsStore(suiteName: "MenuBarUsageTotalTests-source")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.menuBarShowsBrandIconWithPercent = true
        settings.selectedMenuProvider = .codex

        let registry = ProviderRegistry.shared
        for provider in [UsageProvider.codex, .claude] {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(registry.metadata[provider]),
                enabled: true)
        }
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        store._setSnapshotForTesting(Self.snapshot(used: 40), provider: .codex)
        store._setSnapshotForTesting(Self.snapshot(used: 20, weeklyUsed: 96), provider: .claude)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }
        let button = try #require(controller.statusItem.button)

        #expect(settings.unifiedIconSource == .currentSelection)
        controller.updateIcons()
        #expect(button.accessibilityTitle()?.contains("near limit") != true)

        settings.unifiedIconSource = .allProviders
        controller.updateIcons()
        let total = try #require(controller.menuBarUsageTotal())
        #expect(total.providerCount == 2)
        #expect(total.nearLimit.map(\.provider) == [.claude])
        #expect(total.averageRemainingPercent == 32)
        #expect(button.accessibilityTitle()?.contains("Claude") == true)
        #expect(button.accessibilityTitle()?.contains("4%") == true)
        #expect(button.attributedTitle.length > 0)
        #expect(button.image?.isTemplate == true)
        let observed = controller.storeIconObservationSignature()

        // A quota on a provider that is not the primary still reaches the status item.
        store._setSnapshotForTesting(Self.snapshot(used: 41), provider: .codex)
        #expect(controller.storeIconObservationSignature() != observed)

        store._setSnapshotForTesting(Self.snapshot(used: 20, weeklyUsed: 30), provider: .claude)
        controller.updateIcons()
        #expect(button.attributedTitle.length == 0)
        #expect(button.accessibilityTitle()?.contains("near limit") != true)

        // Leaving mid-warning must not strand the capsule on the shared merged status item.
        store._setSnapshotForTesting(Self.snapshot(used: 20, weeklyUsed: 96), provider: .claude)
        controller.updateIcons()
        #expect(button.attributedTitle.length > 0)
        for style in [false, true] {
            settings.unifiedIconSource = .allProviders
            settings.menuBarShowsBrandIconWithPercent = style
            controller.updateIcons()
            #expect(button.accessibilityTitle()?.contains("near limit") == true)
            settings.unifiedIconSource = .currentSelection
            controller.updateIcons()
            #expect(button.accessibilityTitle()?.contains("near limit") != true)
            #expect(button.attributedTitle.containsAttachments == false)
        }
    }

    @Test
    func `a session forecast warns even when the weekly window would last`() throws {
        let settings = testSettingsStore(suiteName: "MenuBarUsageTotalTests-session-forecast")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.unifiedIconSource = .allProviders
        try settings.setProviderEnabled(
            provider: .claude,
            metadata: #require(ProviderRegistry.shared.metadata[.claude]),
            enabled: true)
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let now = Date()
        // One hour in, 60% used: 40 minutes left. The weekly window, used by the layout metric, has about 16 hours.
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 60,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(4 * 3600),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 60,
                    windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(6 * 86400),
                    resetDescription: nil),
                updatedAt: now),
            provider: .claude)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let total = try #require(controller.menuBarUsageTotal(now: now))
        #expect(total.nearLimit.map(\.provider) == [.claude])
        #expect(total.nearLimit.first?.remainingPercent == 40)
    }

    private static func totalController(
        suite: String,
        provider: UsageProvider,
        snapshot: UsageSnapshot) throws -> (StatusItemController, SettingsStore)
    {
        let settings = testSettingsStore(suiteName: suite)
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.unifiedIconSource = .allProviders
        // Merging needs two enabled providers; the one without a snapshot stays out of the total.
        for enabled in [UsageProvider.codex, .claude] {
            try settings.setProviderEnabled(
                provider: enabled,
                metadata: #require(ProviderRegistry.shared.metadata[enabled]),
                enabled: true)
        }
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        store._setSnapshotForTesting(snapshot, provider: provider)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        return (controller, settings)
    }

    @Test
    func `a limit whose reset has passed no longer warns`() throws {
        let now = Date()
        let (controller, _) = try Self.totalController(
            suite: "MenuBarUsageTotalTests-reset",
            provider: .codex,
            snapshot: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 1,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 100,
                    windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(-10),
                    resetDescription: nil),
                updatedAt: now))
        defer { controller.releaseStatusItemsForTesting() }

        let total = try #require(controller.menuBarUsageTotal(now: now))
        #expect(total.nearLimit.isEmpty)
        #expect(total.averageRemainingPercent == 99)
    }

    @Test
    func `the warning follows the clock on manual refresh in every menu bar style`() throws {
        let now = Date()
        // One hour in at 60% used warns; 35 idle minutes later the same usage lasts more than an hour.
        let (controller, settings) = try Self.totalController(
            suite: "MenuBarUsageTotalTests-clock",
            provider: .claude,
            snapshot: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 60,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(4 * 3600),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now))
        defer { controller.releaseStatusItemsForTesting() }

        #expect(try #require(controller.menuBarUsageTotal(now: now)).nearLimit.map(\.provider) == [.claude])
        #expect(try #require(controller.menuBarUsageTotal(now: now.addingTimeInterval(35 * 60))).nearLimit.isEmpty)

        controller.updateIcons()
        #expect(controller._test_isMenuBarCountdownRefreshScheduled())
        settings.unifiedIconSource = .currentSelection
        controller.updateIcons()
        #expect(!controller._test_isMenuBarCountdownRefreshScheduled())
    }

    @Test
    func `all providers choice is opt in and persists`() {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: "MenuBarUsageTotalTests-prefs", userDefaults: defaults)
        defer { settings.configFileWatcher?.stop() }
        #expect(settings.unifiedIconSource == .currentSelection)
        settings.unifiedIconSource = .allProviders
        #expect(defaults.string(forKey: "unifiedIconSource") == "allProviders")
        #expect(!settings.menuBarShowsHighestUsage)
    }

    @Test
    func `high contrast tints the neutral part instead of using a template`() throws {
        let total = try #require(MenuBarUsageTotal(entries: [
            Entry(provider: .claude, remainingPercent: 62, isStale: false),
        ]))
        let options = MenuBarLayoutRenderOptions(
            size: .regular,
            highContrast: true,
            showUsed: false,
            conditionals: [],
            appearanceName: NSAppearance.Name.darkAqua.rawValue,
            isDebugApp: false,
            isStale: false,
            now: Date())
        let rendered = MenuBarLayoutRenderer.renderUsageTotal(total, logo: nil, options: options)
        #expect(rendered.leadingIcon == nil)
        #expect(rendered.attributedTitle.length > 0)
    }
}

extension MenuBarUsageTotalTests {
    @Test(arguments: [false, true])
    func `saved vertical adjustment moves the actual normal contrast leading pixels`(warning: Bool) throws {
        let total = try #require(MenuBarUsageTotal(entries: [
            Entry(provider: .claude, remainingPercent: warning ? 8 : 62, isStale: false),
        ]))
        let logo = try #require(ProviderBrandIcon.image(for: .claude))
        let original = MenuBarLayoutRenderer.renderUsageTotal(total, logo: logo, options: Self.options())
        let originalImage = try #require(original.leadingIcon)
        for scale in [1, 2] {
            let before = try Self.leadingAlphaCentroid(originalImage, scale: scale)
            let calibration = try Self.leadingAlphaCentroid(Self.calibrationImage(shift: 0), scale: scale)
            for adjustment in [-3, 3] {
                let calibrated = try Self.leadingAlphaCentroid(
                    Self.calibrationImage(shift: adjustment), scale: scale)
                let expectedDelta = calibrated - calibration
                // This independent drawing calibrates bitmap y orientation and pixel-to-point conversion.
                #expect(abs(abs(expectedDelta) - CGFloat(abs(adjustment))) < 0.01)
                let shifted = MenuBarLayoutRenderer.renderUsageTotal(
                    total, logo: logo, options: Self.options(verticalAdjustment: adjustment))
                let shiftedImage = try #require(shifted.leadingIcon)
                let after = try Self.leadingAlphaCentroid(shiftedImage, scale: scale)
                #expect(abs((after - before) - expectedDelta) < 0.25)
                #expect(shiftedImage.isTemplate == originalImage.isTemplate)
                #expect(shifted.statusItemWidth(gap: .regular) == original.statusItemWidth(gap: .regular))
                #expect(shifted.accessibilityLabel == original.accessibilityLabel)
            }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func `native warning capsule pixels translate and clip throughout the saved adjustment range`(
        highContrast: Bool, dark: Bool) throws
    {
        for scale in [1, 2] {
            let original = try Self.nativeWarningCapsuleBitmap(
                highContrast: highContrast, dark: dark, adjustment: 0, scale: scale)
            #expect(Self.pixelMask(original, redOnly: true).filter(\.self).count > 20)
            for adjustment in [-20, -5, -3, 3, 5, 20] {
                let shifted = try Self.nativeWarningCapsuleBitmap(
                    highContrast: highContrast, dark: dark, adjustment: adjustment, scale: scale)
                let pixelShift = try Self.calibratedPixelShift(adjustment: adjustment, scale: scale)
                Self.expectTranslatedMask(
                    original: original,
                    shifted: shifted,
                    pixelShift: pixelShift,
                    redOnly: true)
            }
        }
    }

    private static func nativeWarningCapsuleBitmap(
        highContrast: Bool, dark: Bool, adjustment: Int, scale: Int) throws -> NSBitmapImageRep
    {
        _ = NSApplication.shared
        let appearanceName = dark ? NSAppearance.Name.darkAqua : .aqua
        let appearance = try #require(NSAppearance(named: appearanceName))
        let total = try #require(MenuBarUsageTotal(entries: [
            Entry(provider: .claude, remainingPercent: 8, isStale: false),
        ]))
        let logo = try #require(ProviderBrandIcon.image(for: .claude))
        let options = MenuBarLayoutRenderOptions(
            size: .regular,
            highContrast: highContrast,
            showUsed: false,
            conditionals: [],
            appearanceName: appearanceName.rawValue,
            isDebugApp: false,
            now: Date(timeIntervalSince1970: 1_793_000_000),
            verticalAdjustment: adjustment)
        let rendered = MenuBarLayoutRenderer.renderUsageTotal(total, logo: logo, options: options)
        let width = rendered.statusItemWidth(gap: .regular)
        let bounds = NSRect(x: 0, y: 0, width: width, height: 22)
        let canvas = NSView(frame: bounds)
        canvas.appearance = appearance
        let button = NSButton(frame: bounds)
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleNone
        button.alignment = .center
        button.appearance = appearance
        button.attributedTitle = rendered.attributedTitle
        button.image = rendered.leadingIcon.map {
            MenuBarLayoutRenderer.attachmentImage($0, tint: .labelColor)
        }
        button.setAccessibilityLabel(rendered.accessibilityLabel)
        canvas.addSubview(button)
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = canvas
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        canvas.layoutSubtreeIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(width)) * scale,
            pixelsHigh: 22 * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0))
        bitmap.size = bounds.size
        appearance.performAsCurrentDrawingAppearance {
            button.cacheDisplay(in: button.bounds, to: bitmap)
        }
        return bitmap
    }

    private static func calibratedPixelShift(adjustment: Int, scale: Int) throws -> Int {
        // Use a small fully visible movement to calibrate bitmap orientation independently,
        // then extrapolate in points: at ±20 the reference rectangle itself would be clipped.
        let before = try Self.leadingAlphaCentroid(Self.calibrationImage(shift: 0), scale: scale)
        let after = try Self.leadingAlphaCentroid(Self.calibrationImage(shift: 3), scale: scale)
        #expect(abs(abs(after - before) - 3) < 0.01)
        let direction: CGFloat = after > before ? 1 : -1
        return Int((direction * CGFloat(adjustment * scale)).rounded())
    }

    private static func pixelMask(_ bitmap: NSBitmapImageRep, redOnly: Bool) -> [Bool] {
        var mask: [Bool] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    mask.append(false)
                    continue
                }
                // The red mask excludes Claude's orange mark; alpha alone covers all neutral attachments.
                mask.append(redOnly
                    ? color.alphaComponent > 0.1 && color.redComponent > 0.6 && color.greenComponent < 0.3 && color
                    .blueComponent < 0.3
                    : color.alphaComponent > 0.1)
            }
        }
        return mask
    }

    private static func expectTranslatedMask(
        original: NSBitmapImageRep, shifted: NSBitmapImageRep, pixelShift: Int, redOnly: Bool)
    {
        #expect(shifted.pixelsWide == original.pixelsWide)
        #expect(shifted.pixelsHigh == original.pixelsHigh)
        guard shifted.pixelsWide == original.pixelsWide, shifted.pixelsHigh == original.pixelsHigh else { return }
        let width = original.pixelsWide
        let height = original.pixelsHigh
        let originalMask = Self.pixelMask(original, redOnly: redOnly)
        let actualMask = Self.pixelMask(shifted, redOnly: redOnly)
        var expected: [Bool] = []
        for y in 0..<height {
            for x in 0..<width {
                let sourceY = y - pixelShift
                expected.append(sourceY >= 0 && sourceY < height ? originalMask[sourceY * width + x] : false)
            }
        }
        let mismatches = zip(expected, actualMask).filter { $0 != $1 }.count
        // Integer translation preserves the shape, including clipping or disappearance at large nudges.
        // A small raster tolerance permits edge antialiasing without accepting recentering.
        let allowedMismatch = max(2, expected.filter(\.self).count / 50)
        #expect(mismatches <= allowedMismatch)
    }

    private static func calibrationImage(shift: Int) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 22), flipped: false) { _ in
            NSColor.black.setFill()
            NSRect(x: 2, y: CGFloat(8 + shift), width: 8, height: 4).fill()
            return true
        }
    }

    private static func leadingBitmap(_ image: NSImage, scale: Int) throws -> NSBitmapImageRep {
        let canvas = NSSize(width: ceil(image.size.width), height: 22)
        let context = try #require(CGContext(
            data: nil,
            width: Int(canvas.width) * scale,
            height: Int(canvas.height) * scale,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        // Match the status button's image centering without using the production offset helper.
        let origin = NSPoint(x: 0, y: (canvas.height - image.size.height) / 2)
        image.draw(in: NSRect(origin: origin, size: image.size))
        return try NSBitmapImageRep(cgImage: #require(context.makeImage()))
    }

    private static func leadingAlphaCentroid(_ image: NSImage, scale: Int) throws -> CGFloat {
        let bitmap = try Self.leadingBitmap(image, scale: scale)
        var mass: CGFloat = 0
        var weightedY: CGFloat = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                mass += alpha
                weightedY += (CGFloat(y) + 0.5) * alpha
            }
        }
        try #require(mass > 1)
        return weightedY / mass / CGFloat(scale)
    }
}
