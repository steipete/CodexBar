import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

/// Regression coverage for the Touch Bar tap bug: `NSHostingView` (SwiftUI) never receives
/// touch input under the private `presentSystemModalTouchBar:` path, so neither `.onTapGesture`
/// nor a SwiftUI `Button` registered taps on physical hardware. The fix moved this content to
/// plain AppKit (`TouchBarAppKitViews.swift`) — these tests fail if that regresses, either by
/// reintroducing SwiftUI hosting as the item's view, or by breaking the tap-driven state
/// machine that swaps the overview row for the expanded graph.
@MainActor
struct PersistentUsageTouchBarControllerTests {
    private static let itemIdentifier = NSTouchBarItem.Identifier("com.steipete.codexbar.persistentItem")

    @Test
    func `touch bar item view is plain AppKit, never a SwiftUI hosting view`() {
        let (controller, _) = Self.makeController(suite: "PersistentTouchBar-plainAppKit")
        let bar = NSTouchBar()
        let item = controller.touchBar(bar, makeItemForIdentifier: Self.itemIdentifier)

        let view = try! #require(item?.view)
        #expect(view is NSStackView, "item.view must be a plain NSStackView — an NSHostingView here silently drops all touch input under presentSystemModalTouchBar:")
        #expect(String(describing: type(of: view)).contains("Hosting") == false)
    }

    @Test
    func `tapping a provider card invokes its onTap closure via the real gesture recognizer`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .codex)
        let card = TouchBarProviderCardView(provider: .codex)
        card.apply(descriptor: descriptor, snapshot: nil)

        let recognizer = try! #require(card.gestureRecognizers.compactMap { $0 as? NSClickGestureRecognizer }.first)
        #expect(
            recognizer.allowedTouchTypes.contains(.direct),
            "Touch Bar delivers NSTouch as .direct, not mouse/indirect — a recognizer missing this never fires on real hardware even though it's structurally attached (this is what actually broke both prior fix rounds)"
        )

        var tapped = false
        card.onTap = { tapped = true }
        // Fires the same @objc action the gesture recognizer calls on a real tap —
        // exercises the actual dispatch path, not just the closure assignment.
        card.perform(Selector(("handleTap")))

        #expect(tapped, "tapping the card must invoke onTap through its gesture recognizer's action")
    }

    @Test
    func `tapping a provider graph invokes its onTap closure via the real gesture recognizer`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .codex)
        let graph = TouchBarProviderGraphView(provider: .codex)
        graph.apply(descriptor: descriptor, snapshot: nil, window: .primary)

        var tapped = false
        graph.onTap = { tapped = true }
        graph.perform(Selector(("handleTap")))

        #expect(tapped, "tapping the graph row must invoke onTap through its gesture recognizer's action")
    }

    @Test
    func `card tap expands to 5h, graph tap advances to weekly, graph tap again collapses to cards`() {
        let (controller, store) = Self.makeController(suite: "PersistentTouchBar-expandCollapse")
        store.snapshots[.codex] = UsageSnapshot(
            primary: RateWindow(usedPercent: 40, windowMinutes: 300, resetsAt: Date().addingTimeInterval(3600), resetDescription: nil),
            secondary: RateWindow(usedPercent: 25, windowMinutes: 10080, resetsAt: Date().addingTimeInterval(86400), resetDescription: nil),
            updatedAt: Date())

        let bar = NSTouchBar()
        let item = try! #require(controller.touchBar(bar, makeItemForIdentifier: Self.itemIdentifier))
        let stack = try! #require(item.view as? NSStackView)

        let card = try! #require(stack.arrangedSubviews.compactMap { $0 as? TouchBarProviderCardView }.first)
        #expect(card.provider == .codex)

        card.perform(Selector(("handleTap")))
        #expect(
            stack.arrangedSubviews.contains { $0 is TouchBarProviderGraphView },
            "tapping a card must swap the row to the expanded graph view"
        )
        #expect(
            stack.arrangedSubviews.contains { $0 is TouchBarProviderCardView } == false,
            "the overview cards must be gone while a provider is expanded"
        )
        var graph = try! #require(stack.arrangedSubviews.compactMap { $0 as? TouchBarProviderGraphView }.first)
        #expect(
            graph.accessibilityLabel()?.contains("5h") == true,
            "the graph must open on the 5h window first"
        )

        graph.perform(Selector(("handleTap")))
        graph = try! #require(stack.arrangedSubviews.compactMap { $0 as? TouchBarProviderGraphView }.first)
        #expect(
            graph.accessibilityLabel()?.contains("wk") == true,
            "the second tap must advance the same graph row to the weekly window, not collapse yet"
        )

        graph.perform(Selector(("handleTap")))
        #expect(
            stack.arrangedSubviews.contains { $0 is TouchBarProviderCardView },
            "the third tap (after 5h and weekly) must revert back to the overview cards"
        )
    }

    @Test
    func `touch bar rate row and graph view display reset label using absolute Reset at phrasing`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .codex)
        let card = TouchBarProviderCardView(provider: .codex)
        let resetsAt = Date().addingTimeInterval(7200)
        let window = RateWindow(usedPercent: 40, windowMinutes: 300, resetsAt: resetsAt, resetDescription: nil)
        let snapshot = UsageSnapshot(primary: window, secondary: nil, updatedAt: Date())

        card.apply(descriptor: descriptor, snapshot: snapshot)

        #expect(
            card.primaryRow.resetLabel.stringValue.starts(with: "Reset at "),
            "Touch Bar rate row reset label must use absolute 'Reset at ' phrasing, not relative 'in Xh Ym'"
        )

        let graph = TouchBarProviderGraphView(provider: .codex)
        graph.apply(descriptor: descriptor, snapshot: snapshot, window: .primary)

        #expect(
            graph.resetLabel.stringValue.contains(" · Reset at "),
            "Touch Bar graph row reset label must use absolute 'Reset at ' phrasing"
        )
    }

    @Test
    func `touch bar window label falls back to provider metadata for non time-boxed windows`() {
        // Kiro's primary/secondary windows are monthly credit grants (windowMinutes: nil),
        // not a real 5h/weekly rolling window — labeling them "5h"/"wk" is wrong. The card
        // and graph rows must fall back to Kiro's own ProviderMetadata.sessionLabel/weeklyLabel
        // ("Credits"/"Bonus") instead of assuming Codex's window shape.
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .kiro)
        let window = RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil)

        let card = TouchBarProviderCardView(provider: .kiro)
        card.apply(descriptor: descriptor, snapshot: UsageSnapshot(primary: window, secondary: nil, updatedAt: Date()))
        #expect(card.primaryRow.nameLabel.stringValue == "Credits")

        let graph = TouchBarProviderGraphView(provider: .kiro)
        graph.apply(descriptor: descriptor, snapshot: UsageSnapshot(primary: window, secondary: nil, updatedAt: Date()), window: .primary)
        #expect(graph.accessibilityLabel()?.contains("Credits") == true)
        #expect(graph.accessibilityLabel()?.contains("5h") == false)

        // Codex's real 5h window still gets the compact label, unaffected by the fallback.
        let codexDescriptor = ProviderDescriptorRegistry.descriptor(for: .codex)
        let codexWindow = RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
        let codexCard = TouchBarProviderCardView(provider: .codex)
        codexCard.apply(descriptor: codexDescriptor, snapshot: UsageSnapshot(primary: codexWindow, secondary: nil, updatedAt: Date()))
        #expect(codexCard.primaryRow.nameLabel.stringValue == "5h")
    }

    @Test
    func `frontmost-app gating matches developer-tools category, not a hardcoded app list`() {
        let ideBundle = Self.makeTestAppBundle(category: "public.app-category.developer-tools")
        #expect(PersistentUsageTouchBarController.isDeveloperToolsApp(bundleURL: ideBundle) == true)

        let terminalBundle = Self.makeTestAppBundle(category: "public.app-category.utilities")
        #expect(
            PersistentUsageTouchBarController.isDeveloperToolsApp(bundleURL: terminalBundle) == false,
            "plain terminal emulators (Utilities category) must stay excluded — the definition is IDE/multiplexer-like, not any shell"
        )

        #expect(PersistentUsageTouchBarController.isDeveloperToolsApp(bundleURL: nil) == false)
    }

    @Test
    func `frontmost-app gating falls back to bundle ID for apps with no declared category`() {
        // Zed ships with no LSApplicationCategoryType key at all — category check alone would
        // wrongly exclude it, so it's patched via a small bundle-ID fallback list.
        let zedLikeBundle = Self.makeTestAppBundle(bundleIdentifier: "dev.zed.Zed", category: nil)
        #expect(PersistentUsageTouchBarController.isDeveloperToolsApp(bundleURL: zedLikeBundle) == true)

        let unknownBundle = Self.makeTestAppBundle(bundleIdentifier: "com.example.unknown-editor", category: nil)
        #expect(PersistentUsageTouchBarController.isDeveloperToolsApp(bundleURL: unknownBundle) == false)
    }

    private static func makeTestAppBundle(
        bundleIdentifier: String = "com.example.test",
        category: String?) -> URL
    {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TouchBarGatingTest-\(UUID().uuidString).app")
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        try! FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleIdentifier": bundleIdentifier]
        if let category { plist["LSApplicationCategoryType"] = category }
        let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try! data.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return bundleURL
    }

    @Test
    func `touch bar progress capsule view has horizontal fill geometry constraints`() {
        let rateRow = TouchBarRateRowView(label: "5h")
        let capsuleConstraints = rateRow.capsule.constraints
        let widthConstraint = capsuleConstraints.first { $0.firstAttribute == .width }
        let heightConstraint = capsuleConstraints.first { $0.firstAttribute == .height }

        #expect(widthConstraint?.constant == 50, "capsule in rate row should have horizontal bar width ~50pt")
        #expect(heightConstraint?.constant == 5, "capsule in rate row should have horizontal bar height ~5pt")
    }

    // MARK: - Fixtures

    private static func makeController(suite: String) -> (PersistentUsageTouchBarController, UsageStore) {
        let settings = Self.makeSettingsStore(suite: suite)
        settings.setProviderEnabled(provider: .codex, metadata: ProviderRegistry.shared.metadata[.codex]!, enabled: true)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let controller = PersistentUsageTouchBarController(settings: settings, store: store)
        return (controller, store)
    }

    private static func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            performInitialProviderDetection: false)
    }
}
