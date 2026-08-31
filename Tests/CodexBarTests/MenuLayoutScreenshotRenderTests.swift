import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Developer tool, skipped by default: renders the stacked (before) and compact
/// (after) claude-swap multi-account menu layouts to PNGs for documentation.
///
/// Run with:
///   CODEXBAR_SCREENSHOT_DIR=docs/screenshots swift test --filter MenuLayoutScreenshotRenderTests
@MainActor
final class MenuLayoutScreenshotRenderTests: XCTestCase {
    private static let width: CGFloat = 320
    private static let now = Date(timeIntervalSince1970: 1_782_000_000)

    func test_renderCatalanLocalizationProof() throws {
        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_CATALAN_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_CATALAN_SCREENSHOT_DIR to render the Catalan localization proof.")
        }
        XCTAssertTrue(SettingsStore.isRunningTests)
        guard SettingsStore.isRunningTests else { return }
        let previousOverride = KeychainAccessGate.currentOverrideForTesting
        defer {
            if let previousOverride {
                KeychainAccessGate.isDisabled = previousOverride
            } else {
                KeychainAccessGate.resetOverrideForTesting()
            }
        }
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalan-proof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try CodexCredentialFileAccess.withFixtureScope(.init()) {
            try OpenAIDashboardCacheStore.$cacheURLOverride.withValue(root.appendingPathComponent("dashboard.json")) {
                try CodexBarLocalizationOverride.$appLanguage.withValue("ca") {
                    let settings = testSettingsStore(
                        suiteName: "MenuLayoutScreenshotRenderTests-catalan",
                        config: testConfigWithAllProvidersDisabled(),
                        prepareDefaults: { defaults in
                            defaults.set(AppGroupSupport.migrationVersion, forKey: AppGroupSupport.migrationVersionKey)
                            defaults.set(true, forKey: "debugDisableKeychainAccess")
                        })
                    let state = CloudSyncState()
                    state.availability = .noICloudAccount
                    let store = UsageStore(
                        fetcher: UsageFetcher(environment: [:]),
                        browserDetection: BrowserDetection(
                            homeDirectory: root.path,
                            fileExists: { _ in false },
                            directoryContents: { _ in nil }),
                        settings: settings,
                        historicalUsageHistoryStore: HistoricalUsageHistoryStore(
                            fileURL: root.appendingPathComponent("history.json")),
                        planUtilizationHistoryStore: PlanUtilizationHistoryStore(
                            directoryURL: root.appendingPathComponent("plan-history")),
                        startupBehavior: .testing,
                        environmentBase: [:],
                        widgetSnapshotURL: root.appendingPathComponent("widget.json"))
                    let fixture = try CursorOverviewProofFixture.make()
                    let group = try XCTUnwrap(fixture.model.groups.first)
                    // Render production views, with no engine, providers, hooks, or credential access running.
                    // Offscreen Forms do not expose their children through the accessibility traversal.
                    let views: [(String, AnyView, [String])] = [
                        ("sidebar", AnyView(SettingsSidebarView(
                            settings: settings, store: store, selection: .constant(.plugins))
                            .frame(width: SettingsPane.sidebarMinWidth, height: 620)), []),
                        ("icloud", AnyView(ICloudSyncPane(settings: settings, state: state)
                                .frame(width: 560, height: 600)), []),
                        ("hooks", AnyView(HooksPane(settings: settings)
                                .frame(width: 560, height: 350)), []),
                        ("layout", AnyView(MenuBarLayoutEditor(settings: settings, store: store)
                                .frame(width: 560).padding(16)), ["menu_bar_layout_drag_remove"]),
                        ("spend", AnyView(SpendDashboardCurrencySection(group: group, requestedDays: 30)
                                .padding(24).frame(width: 680)), ["Input", "Cache write", "List-price equivalent"]),
                    ]
                    for dark in [false, true] {
                        for (name, content, keys) in views {
                            let view = AnyView(content
                                .environment(\.locale, Locale(identifier: "ca_ES"))
                                .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                                .environment(\.colorScheme, dark ? .dark : .light)
                                .environment(\.displayScale, 2)
                                .environment(\.accessibilityEnabled, true)
                                .background(Color(nsColor: .windowBackgroundColor)))
                            let hosting = NSHostingView(rootView: view)
                            hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                            let stem = "catalan-\(name)-\(dark ? "dark" : "light")"
                            let data = name == "sidebar"
                                ? Self.pngDataWithWindow(hosting: hosting)
                                : Self.pngData(hosting: hosting)
                            let png = try XCTUnwrap(data)
                            XCTAssertFalse(png.isEmpty)
                            try png.write(to: directory.appendingPathComponent("\(stem).png"))
                            let accessibility = Self.accessibilityText(hosting)
                            try accessibility.write(
                                to: directory.appendingPathComponent("\(stem)-accessibility.txt"),
                                atomically: true,
                                encoding: .utf8)
                            for key in keys {
                                XCTAssertTrue(accessibility.contains(L(key)), "\(stem): missing \(key)")
                            }
                        }
                    }
                    XCTAssertTrue(store.snapshots.isEmpty)
                    XCTAssertFalse(settings.iCloudSyncEnabled)
                    XCTAssertFalse(settings.hooksEnabled)
                }
            }
        }
    }

    func test_renderCursorOverviewCoverageProof() throws {
        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_CURSOR_OVERVIEW_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_CURSOR_OVERVIEW_SCREENSHOT_DIR to render the Cursor Overview proof.")
        }
        // This override changes assertions only; the fixture and production renderer are identical.
        let expectedDays = ProcessInfo.processInfo.environment["CODEXBAR_CURSOR_OVERVIEW_EXPECTED_DAYS"] ?? "30"
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let fixture = try CursorOverviewProofFixture.make()
            XCTAssertEqual(fixture.model.groups.count, 1)
            XCTAssertEqual(fixture.model.groups.first?.coveredDayCount, 30)
            XCTAssertEqual(fixture.model.groups.first?.totalCost, 12)
            XCTAssertEqual(fixture.model.groups.first?.totalTokens, 1000)
            XCTAssertEqual(fixture.counts.total, 2)
            XCTAssertEqual(fixture.counts.cost, 1)
            XCTAssertEqual(fixture.counts.tokens, 1)
            XCTAssertTrue(fixture.summary.isPartial)
            try CursorOverviewProofFixture.eventJSON.write(
                to: directory.appendingPathComponent("input.json"), atomically: true, encoding: .utf8)
            for dark in [false, true] {
                let view = AnyView(OverviewSpendSummaryCardView(summary: fixture.summary, days: 30, width: 310)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.displayScale, 2)
                    .environment(\.accessibilityEnabled, true)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let name = "cursor-overview-\(dark ? "dark" : "light")"
                let png = try XCTUnwrap(Self.pngData(hosting: hosting))
                XCTAssertEqual(hosting.frame.width, 310)
                XCTAssertFalse(png.isEmpty)
                try png.write(to: directory.appendingPathComponent("\(name).png"))
                let accessibility = Self.accessibilityText(hosting)
                try accessibility.write(
                    to: directory.appendingPathComponent("\(name)-accessibility.txt"),
                    atomically: true,
                    encoding: .utf8)
                for text in [
                    "Coverage: \(expectedDays) / 30", "~$12.00", "1 of 2 subscriptions have spend", "~1K tokens",
                    "Priced 1 · Unpriced 0 · Unmetered 0 · Estimated 0", "List-price equivalent",
                ] {
                    XCTAssertTrue(accessibility.contains(text), accessibility)
                }
            }
        }
    }

    func test_renderOpenRouterLimitClarityProof() async throws {
        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_OPENROUTER_CLARITY_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_OPENROUTER_CLARITY_SCREENSHOT_DIR to render the OpenRouter proof.")
        }
        let snapshot = try await OpenRouterLimitTestSupport.snapshot()
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for language in ["en", "de"] {
            try CodexBarLocalizationOverride.$appLanguage.withValue(language) {
                for showUsed in [false, true] {
                    let model = try OpenRouterLimitTestSupport.model(snapshot, showUsed: showUsed)
                    for dark in [false, true] {
                        for sectioned in [false, true] {
                            let content = sectioned
                                ? AnyView(UsageMenuCardHeaderAndUsageSectionView(
                                    model: model,
                                    layoutModel: model,
                                    bottomPadding: UsageMenuCardLayout.sectionBottomPadding,
                                    width: 310))
                                : AnyView(UsageMenuCardView(model: model, width: 310))
                            let view = AnyView(content
                                .environment(\.locale, Locale(identifier: language == "en" ? "en_US_POSIX" : "de_DE"))
                                .environment(\.colorScheme, dark ? .dark : .light)
                                .environment(\.displayScale, 2)
                                .environment(\.accessibilityEnabled, true)
                                .background(Color(nsColor: .windowBackgroundColor)))
                            let hosting = NSHostingView(rootView: view)
                            hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                            let name = "openrouter-\(language)-\(dark ? "dark" : "light")"
                                + "-\(sectioned ? "sectioned" : "card")-\(showUsed ? "used" : "remaining")"
                            let png = try XCTUnwrap(Self.pngData(hosting: hosting))
                            XCTAssertEqual(hosting.frame.width, 310)
                            try png.write(to: directory.appendingPathComponent("\(name).png"))
                            // Inspect hosted accessibility children independently of pixels and model text.
                            let accessibility = Self.accessibilityText(hosting)
                            try accessibility.write(
                                to: directory.appendingPathComponent("\(name)-accessibility.txt"),
                                atomically: true,
                                encoding: .utf8)
                            XCTAssertTrue(accessibility.contains("$1.90"), accessibility)
                            XCTAssertTrue(accessibility.contains("$30.00"), accessibility)
                            XCTAssertTrue(accessibility.contains(L("API key limit")), accessibility)
                            XCTAssertTrue(accessibility.contains(L(showUsed ? "Usage used" : "Usage remaining")))
                            XCTAssertTrue(accessibility.contains(L("%d percent", showUsed ? 0 : 100)))
                            XCTAssertTrue(accessibility.contains(L("Spending cap, not balance")), accessibility)
                        }
                    }
                }
            }
        }
    }

    private static func accessibilityText(_ element: Any, depth: Int = 0) -> String {
        guard depth < 30, let accessible = element as? NSObject else { return "" }
        // SwiftUI nodes implement these public selectors without adopting the full NSAccessibility protocol.
        let fields = [
            #selector(NSAccessibilityProtocol.accessibilityRole),
            #selector(NSAccessibilityProtocol.accessibilityLabel),
            #selector(NSAccessibilityProtocol.accessibilityValue),
            #selector(NSAccessibilityProtocol.accessibilityValueDescription),
            #selector(NSAccessibilityProtocol.accessibilityHelp),
        ].compactMap { selector in
            self.accessibilityProperty(accessible, selector: selector).map { String(describing: $0) }
        }.joined(separator: " | ")
        let children = self.accessibilityProperty(
            accessible, selector: #selector(NSAccessibilityProtocol.accessibilityChildren)) as? [Any] ?? []
        return ([fields] + children.map {
            self.accessibilityText($0, depth: depth + 1)
        }).joined(separator: "\n")
    }

    private static func accessibilityProperty(_ element: NSObject, selector: Selector) -> Any? {
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue()
    }

    func test_renderLayoutOverrideDisclosureProof() throws {
        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_LAYOUT_OVERRIDE_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_LAYOUT_OVERRIDE_SCREENSHOT_DIR to render the layout override proof.")
        }
        XCTAssertTrue(SettingsStore.isRunningTests)
        guard SettingsStore.isRunningTests else { return }
        XCTAssertTrue(CodexCredentialFileAccess.isTestContext)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("layout-override-proof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // This XCTest needs no credential files; keep authorization empty and the dashboard cache temporary.
        try CodexCredentialFileAccess.withFixtureScope(.init()) {
            try OpenAIDashboardCacheStore.$cacheURLOverride.withValue(root.appendingPathComponent("dashboard.json")) {
                try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
                    let order: [UsageProvider] = [.claude, .cursor]
                    let config =
                        CodexBarConfig(providers: (order + UsageProvider.allCases.filter { !order.contains($0) })
                            .map { ProviderConfig(id: $0.instanceID, enabled: order.contains($0)) })
                    let settings = testSettingsStore(
                        suiteName: "MenuLayoutScreenshotRenderTests-overrides",
                        config: config,
                        prepareDefaults: { defaults in
                            defaults.set(AppGroupSupport.migrationVersion, forKey: AppGroupSupport.migrationVersionKey)
                            defaults.set(true, forKey: "debugDisableKeychainAccess")
                        })
                    settings.menuBarIconStyle = .iconAndPercent
                    let global = MenuBarLayout(lines: [[.providerName, .space, .percent(window: .session)]])
                    let override = MenuBarLayout(lines: [[.percent(window: .weekly)]])
                    settings.setMenuBarLayout(global, for: nil)
                    settings.setMenuBarLayout(override, for: .claude)
                    let browserDetection = BrowserDetection(
                        homeDirectory: root.path,
                        fileExists: { _ in false },
                        directoryContents: { _ in nil })
                    let store = UsageStore(
                        fetcher: UsageFetcher(environment: [:]),
                        browserDetection: browserDetection,
                        settings: settings,
                        historicalUsageHistoryStore: HistoricalUsageHistoryStore(
                            fileURL: root.appendingPathComponent("history.json")),
                        planUtilizationHistoryStore: PlanUtilizationHistoryStore(
                            directoryURL: root.appendingPathComponent("plan-history")),
                        startupBehavior: .testing,
                        environmentBase: [:],
                        widgetSnapshotURL: root.appendingPathComponent("widget.json"))
                    XCTAssertEqual(store.enabledFirstPartyProvidersForDisplay(), order)
                    XCTAssertTrue(store.snapshots.isEmpty)
                    XCTAssertEqual(settings.menuBarLayoutForGlobalEditing(representativeProvider: .claude), global)
                    XCTAssertEqual(settings.menuBarLayout(for: .claude), override)

                    let view = AnyView(MenuBarLayoutEditor(settings: settings, store: store)
                        .frame(width: 560)
                        .padding(16)
                        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                        .environment(\.colorScheme, .dark)
                        .background(Color(nsColor: .windowBackgroundColor)))
                    let data = try XCTUnwrap(Self.pngData(for: view))
                    let directory = URL(fileURLWithPath: dir, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try data.write(to: directory.appendingPathComponent("layout-override.png"))
                    XCTAssertEqual(settings.menuBarLayoutOverrides, [.claude: override])
                    XCTAssertEqual(settings.menuBarLayout, global)
                }
            }
        }
    }

    func test_renderClaudeExtraUsageFillProof() throws {
        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_CLAUDE_EXTRA_USAGE_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_CLAUDE_EXTRA_USAGE_SCREENSHOT_DIR to render the Claude Extra Usage proof.")
        }

        let metadata = try XCTUnwrap(ProviderDefaults.metadata[.claude])
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 25,
                limit: 100,
                currencyCode: "USD",
                period: "Monthly",
                updatedAt: Self.now),
            updatedAt: Self.now)
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for showUsed in [true, false] {
            let model = UsageMenuCardView.Model.make(.init(
                provider: .claude,
                metadata: metadata,
                snapshot: snapshot,
                credits: nil,
                creditsError: nil,
                dashboard: nil,
                dashboardError: nil,
                tokenSnapshot: nil,
                tokenError: nil,
                account: AccountInfo(email: nil, plan: nil),
                isRefreshing: false,
                lastError: nil,
                usageBarsShowUsed: showUsed,
                resetTimeDisplayStyle: .countdown,
                tokenCostUsageEnabled: false,
                showOptionalCreditsAndExtraUsage: true,
                hidePersonalInfo: true,
                usesLiveSubtitle: false,
                preferredCurrencyCode: "USD",
                now: Self.now))
            let view = AnyView(UsageMenuCardExtraUsageSectionView(
                model: model,
                topPadding: 12,
                bottomPadding: 12,
                width: Self.width)
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                .environment(\.colorScheme, .dark)
                .background(Color(nsColor: .windowBackgroundColor)))
            let mode = showUsed ? "used" : "remaining"
            let png = try XCTUnwrap(Self.pngData(for: view), "Claude Extra Usage \(mode) render failed")
            let url = directory.appendingPathComponent("claude-extra-usage-\(mode).png")
            try png.write(to: url, options: .atomic)
            print("Wrote \(url.path)")
        }
    }

    func test_renderAntigravitySemanticLayoutProof() throws {
        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_ANTIGRAVITY_LAYOUT_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_ANTIGRAVITY_LAYOUT_SCREENSHOT_DIR to render the Antigravity layout proof.")
        }

        let json = antigravityQuotaSummaryJSON(
            geminiSession: 0.86,
            geminiWeekly: 0.55,
            claudeSession: 1,
            claudeWeekly: 1)
        let snapshot = try AntigravityStatusProbe.parseQuotaSummaryResponse(Data(json.utf8)).toUsageSnapshot()
        let windows = MenuBarLayoutSemanticWindowResolver.windows(provider: .antigravity, snapshot: snapshot)
        let data = MenuBarLayoutRenderData(
            provider: .antigravity,
            iconKey: "antigravity",
            providerName: nil,
            accountLabel: nil,
            laneLabels: MenuBarLayoutLaneLabels(provider: .antigravity, snapshot: snapshot),
            primary: MenuBarLayoutRenderWindow(snapshot.primary),
            secondary: MenuBarLayoutRenderWindow(snapshot.secondary),
            tertiary: MenuBarLayoutRenderWindow(snapshot.tertiary),
            session: MenuBarLayoutRenderWindow(windows.session),
            weekly: MenuBarLayoutRenderWindow(windows.weekly),
            scopedWeekly: nil,
            scopedWeeklyTitle: nil,
            automatic: nil,
            automaticText: nil,
            sessionPace: nil,
            weeklyPace: nil,
            automaticPace: nil,
            runsOut: nil,
            balance: nil,
            costToday: nil,
            cost30d: nil,
            metrics: .unavailable)
        let rendered = MenuBarLayoutRenderer().render(
            layout: MenuBarLayout(lines: [[.percent(window: .session), .separatorDot, .percent(window: .weekly)]]),
            data: data,
            icon: nil,
            options: MenuBarLayoutRenderOptions(
                size: .regular,
                highContrast: false,
                showUsed: false,
                conditionals: [],
                appearanceName: "antigravity-proof",
                isDebugApp: false,
                now: Self.now))
        let view = AnyView(VStack(alignment: .leading, spacing: 12) {
            Text("Antigravity · synthetic quota data")
                .font(.headline)
            Text("Remaining quota · session / weekly")
                .font(.caption)
                .foregroundStyle(.secondary)
            MenuBarLayoutPreviewText(rendered: rendered)
                .frame(height: 30)
        }
        .padding(16)
        .frame(width: Self.width)
        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
        .environment(\.colorScheme, .dark)
        .background(Color(nsColor: .windowBackgroundColor)))

        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(Self.pngData(for: view), "Antigravity layout proof render failed")
        let url = directory.appendingPathComponent("antigravity-semantic-layout.png")
        try png.write(to: url, options: .atomic)
        print("Rendered: \(rendered.attributedTitle.string); accessibility: \(rendered.accessibilityLabel)")
        print("Wrote \(url.path)")
    }

    func test_renderMultiAccountLayoutScreenshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_SCREENSHOT_DIR to render menu layout screenshots.")
        }
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let accounts = Self.screenshotAccounts()
        let before = AnyView(Self.stackedPreview(accounts: accounts))
        let after = AnyView(Self.compactPreview(accounts: accounts))
        for (name, view) in [
            ("claude-multi-account-stacked-before", before),
            ("claude-multi-account-compact-after", after),
        ] {
            let data = try XCTUnwrap(Self.pngData(for: view), "render failed for \(name)")
            let url = directory.appendingPathComponent("\(name).png")
            try data.write(to: url, options: .atomic)
            print("Wrote \(url.path)")
        }
    }

    func test_renderCachedCostRefreshScreenshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_COST_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_COST_SCREENSHOT_DIR to render cached cost screenshots.")
        }
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for isRefreshing in [false, true] {
            let tokenUsage = UsageMenuCardView.Model.TokenUsageSection(
                isRefreshing: isRefreshing,
                sessionLine: "Today: $1.24 · 18.4K tokens",
                monthLine: "Last 30 days: $38.62 · 612K tokens",
                hintLine: "Costs are estimated from local usage.",
                errorLine: nil,
                errorCopyText: nil)
            let view = AnyView(UsageMenuCardCostSectionView(
                model: Self.costModel(tokenUsage: tokenUsage),
                topPadding: 12,
                bottomPadding: 12,
                width: Self.width))
            let suffix = isRefreshing ? "refreshing" : "idle"
            let data = try XCTUnwrap(Self.pngData(for: view), "render failed for cached cost \(suffix)")
            let url = directory.appendingPathComponent("usage-spend-cached-menu-\(suffix).png")
            try data.write(to: url, options: .atomic)
            print("Wrote \(url.path)")
        }
    }

    func test_renderDeepSeekMenuBarLayoutProof() throws {
        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_DEEPSEEK_LAYOUT_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_DEEPSEEK_LAYOUT_SCREENSHOT_DIR to render the DeepSeek layout proof.")
        }
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let settings = testSettingsStore(suiteName: "MenuLayoutScreenshotRenderTests-deepseek")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = UsageProvider.deepseek.instanceID
        if let metadata = ProviderRegistry.shared.metadata[.deepseek] {
            settings.setProviderEnabled(provider: .deepseek, metadata: metadata, enabled: true)
        }
        let layout = MenuBarLayout(lines: [[.resetCountdown, .separatorDot, .resetAbsolute]])
        settings.setMenuBarLayout(layout, for: nil)
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "¥2.23 (Paid: ¥2.23 / Granted: ¥0.00)"),
            secondary: nil,
            updatedAt: Self.now)
        store._setSnapshotForTesting(snapshot, provider: .deepseek)
        store._setErrorForTesting(nil, provider: .deepseek)

        let statusData = controller.menuBarLayoutRenderData(
            provider: .deepseek,
            snapshot: snapshot,
            warningFlash: false,
            now: Self.now)
        let statusRendered = MenuBarLayoutRenderer().render(
            layout: layout,
            data: statusData,
            icon: nil,
            options: MenuBarLayoutRenderOptions(
                size: .regular,
                highContrast: false,
                showUsed: true,
                conditionals: [],
                appearanceName: "proof",
                isDebugApp: false,
                now: Self.now))
        let view = AnyView(VStack(alignment: .leading, spacing: 14) {
            Text("Synthetic DeepSeek custom layout")
                .font(.headline)
            Self.proofRow(title: "Live editor preview") {
                MenuBarLayoutPreview(
                    layout: layout,
                    provider: .deepseek,
                    settings: settings,
                    store: store)
            }
            Self.proofRow(title: "Saved menu-bar render") {
                MenuBarLayoutPreviewText(rendered: statusRendered)
            }
        }
        .padding(18)
        .frame(width: 390)
        .background(Color(nsColor: .windowBackgroundColor)))

        let data = try XCTUnwrap(Self.pngData(for: view), "DeepSeek layout proof render failed")
        let url = directory.appendingPathComponent("deepseek-custom-layout-preview-status-proof.png")
        try data.write(to: url, options: .atomic)
        print("Wrote \(url.path)")
    }

    func test_renderEarlyWeeklyPaceTokenProof() throws {
        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_PACE_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_PACE_SCREENSHOT_DIR to render the early-window pace token proof.")
        }
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let settings = testSettingsStore(suiteName: "MenuLayoutScreenshotRenderTests-pace")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = UsageProvider.zai.instanceID
        if let metadata = ProviderRegistry.shared.metadata[.zai] {
            settings.setProviderEnabled(provider: .zai, metadata: metadata, enabled: true)
        }
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }
        let now = Self.now
        // Weekly window 4 hours in of 7 days (2.38% expected): inside the 1-3% band only the
        // weekly token opens early. The session window is 2 minutes in of 120 (1.67% expected)
        // and stays hidden on its 3% floor.
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 5,
                windowMinutes: 120,
                resetsAt: now.addingTimeInterval(118 * 60),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 5,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(7 * 24 * 60 * 60 - 4 * 60 * 60),
                resetDescription: nil),
            updatedAt: now)
        store._setSnapshotForTesting(snapshot, provider: .zai)
        store._setErrorForTesting(nil, provider: .zai)

        func renderedRow(window: PercentWindow) -> MenuBarLayoutRenderedTitle {
            let layout = MenuBarLayout(lines: [[
                .percent(window: window),
                .separatorDot,
                .pace(window: window),
            ]])
            let data = controller.menuBarLayoutRenderData(
                provider: .zai,
                snapshot: snapshot,
                warningFlash: false,
                now: now)
            return MenuBarLayoutRenderer().render(
                layout: layout,
                data: data,
                icon: nil,
                options: MenuBarLayoutRenderOptions(
                    size: .regular,
                    highContrast: false,
                    showUsed: true,
                    conditionals: [],
                    appearanceName: "proof",
                    isDebugApp: false,
                    now: now))
        }

        let view = AnyView(VStack(alignment: .leading, spacing: 14) {
            Text("Early weekly window pace tokens (synthetic snapshot)")
                .font(.headline)
            Self.proofRow(title: "Weekly token: pace visible (+3%, 1% floor)") {
                MenuBarLayoutPreviewText(rendered: renderedRow(window: .weekly))
            }
            Self.proofRow(title: "Session token: pace hidden (3% floor)") {
                MenuBarLayoutPreviewText(rendered: renderedRow(window: .session))
            }
            Self.proofRow(title: "Automatic token: pace hidden (3% floor)") {
                MenuBarLayoutPreviewText(rendered: renderedRow(window: .automatic))
            }
        }
        .padding(18)
        .frame(width: 430)
        .background(Color(nsColor: .windowBackgroundColor)))

        let data = try XCTUnwrap(Self.pngData(for: view), "early-window pace proof render failed")
        let url = directory.appendingPathComponent("early-weekly-pace-token-proof.png")
        try data.write(to: url, options: .atomic)
        print("Wrote \(url.path)")
    }

    // MARK: - Fixture

    private static func screenshotAccounts() -> [ProviderAccountUsageSnapshot] {
        let list = ClaudeSwapAccountList(
            activeAccountNumber: 1,
            accounts: [
                self.row(1, "alice@example.com", active: true, session: 4, weekly: 1, fable: 0),
                self.row(2, "work@example.com", session: 3, weekly: 0, fable: 0),
                self.row(3, "spare@example.com", session: 0, weekly: 0, fable: 0),
                self.row(4, "team@example.com", session: 0, weekly: 4, fable: 8),
                self.row(5, "burner@example.com", session: 0, weekly: 57, fable: 100),
                self.row(6, "backup@example.com", session: 0, weekly: 0, fable: 0),
            ])
        return ClaudeSwapAccountProjection.accountSnapshots(from: list, now: self.now)
    }

    private static func row(
        _ number: Int,
        _ email: String,
        active: Bool = false,
        session: Double,
        weekly: Double,
        fable: Double) -> ClaudeSwapAccountRow
    {
        ClaudeSwapAccountRow(
            number: number,
            email: email,
            isActive: active,
            usageStatus: .ok,
            fiveHour: ClaudeSwapUsageWindow(usedPercent: session, resetsAt: self.now.addingTimeInterval(4.75 * 3600)),
            sevenDay: ClaudeSwapUsageWindow(usedPercent: weekly, resetsAt: self.now.addingTimeInterval(6.9 * 3600)),
            scoped: [
                ClaudeSwapScopedUsageWindow(
                    name: "Fable",
                    usedPercent: fable,
                    resetsAt: self.now.addingTimeInterval(6.9 * 3600)),
            ])
    }

    private static func cardModel(for account: ProviderAccountUsageSnapshot) -> UsageMenuCardView.Model? {
        guard let metadata = ProviderDefaults.metadata[.claude] else { return nil }
        return UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: account.snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: account.displayLabel, plan: nil),
            planOverride: account.isActive ? L("Active") : L("Switch Account..."),
            isRefreshing: false,
            lastError: account.error,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: false,
            hidePersonalInfo: false,
            now: self.now))
    }

    private static func costModel(
        tokenUsage: UsageMenuCardView.Model.TokenUsageSection) -> UsageMenuCardView.Model
    {
        UsageMenuCardView.Model(
            provider: .codex,
            providerName: "Codex",
            email: "",
            subtitleText: "Updated now",
            subtitleStyle: .info,
            planText: nil,
            metrics: [],
            usageNotes: [],
            openAIAPIUsage: nil,
            inlineUsageDashboard: nil,
            creditsText: nil,
            creditsRemaining: nil,
            creditsProgressPercent: nil,
            creditsScaleText: nil,
            creditsHintText: nil,
            creditsHintCopyText: nil,
            providerCost: nil,
            tokenUsage: tokenUsage,
            placeholder: nil,
            progressColor: .blue)
    }

    // MARK: - Preview composition

    private static func stackedPreview(accounts: [ProviderAccountUsageSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(accounts.enumerated()), id: \.offset) { index, account in
                if let model = self.cardModel(for: account) {
                    UsageMenuCardView(model: model, width: self.width)
                    if index < accounts.count - 1 {
                        Divider().padding(.horizontal, 10)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private static func compactPreview(accounts: [ProviderAccountUsageSnapshot]) -> some View {
        let plan = AccountMenuLayoutPlanner.plan(accounts: accounts)
        let accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let progressColor = UsageMenuCardView.Model.progressColor(for: .claude)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(plan.rows.enumerated()), id: \.offset) { index, row in
                switch row {
                case let .card(accountID):
                    if let account = accountsByID[accountID], let model = self.cardModel(for: account) {
                        UsageMenuCardView(model: model, width: self.width)
                        if index < plan.rows.count - 1 {
                            Divider().padding(.horizontal, 10)
                        }
                    }
                case let .compact(compactRow):
                    MenuCardCompactAccountRowView(
                        model: MenuCardCompactAccountRowView.Model(
                            label: compactRow.label,
                            headroomPercent: compactRow.headroomPercent,
                            severity: compactRow.severity,
                            constraintDetail: compactRow.constraintDetail,
                            hasError: compactRow.hasError,
                            showsBestBadge: compactRow.isBestCandidate),
                        progressColor: progressColor,
                        width: self.width)
                case let .collapsedHealthy(count):
                    MenuCardCollapsedAccountsRowView(count: count, width: self.width)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private static func proofRow(
        title: String,
        @ViewBuilder content: () -> some View)
        -> some View
    {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.background.opacity(0.75)))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(.separator.opacity(0.65), lineWidth: 1))
        }
    }

    // MARK: - Rendering

    private static func pngData(for view: AnyView) -> Data? {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .darkAqua)
        return self.pngData(hosting: hosting)
    }

    private static func pngData(hosting: NSHostingView<AnyView>) -> Data? {
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return nil }
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        else { return nil }
        representation.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: representation) else { return nil }
        hosting.displayIgnoringOpacity(hosting.bounds, in: context)
        return representation.representation(using: .png, properties: [:])
    }
}

extension MenuLayoutScreenshotRenderTests {
    func test_renderSingularResetLabelProof() throws {
        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_RESET_LABEL_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_RESET_LABEL_SCREENSHOT_DIR to render the reset label proof.")
        }
        UsageFormatter.setLocalizationProvider { $0 }
        defer { UsageFormatter.clearLocalizationProvider() }
        let expected = ProcessInfo.processInfo.environment["CODEXBAR_RESET_LABEL_EXPECTED"]
            ?? "Resets Jul 10 at 2:59am (Europe/Prague)"
        let metadata = try XCTUnwrap(ProviderDefaults.metadata[.claude])
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [NamedRateWindow(
                id: "claude-weekly-scoped-example",
                title: "Example Model only",
                window: RateWindow(
                    usedPercent: 68,
                    windowMinutes: 10080,
                    resetsAt: nil,
                    resetDescription: "Reset Jul 10 at 2:59am (Europe/Prague)"))],
            updatedAt: Self.now)
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for style in [ResetTimeDisplayStyle.countdown, .absolute] {
            let model = UsageMenuCardView.Model.make(.init(
                provider: .claude,
                metadata: metadata,
                snapshot: snapshot,
                credits: nil,
                creditsError: nil,
                dashboard: nil,
                dashboardError: nil,
                tokenSnapshot: nil,
                tokenError: nil,
                account: AccountInfo(email: nil, plan: nil),
                isRefreshing: false,
                lastError: nil,
                usageBarsShowUsed: true,
                resetTimeDisplayStyle: style,
                tokenCostUsageEnabled: false,
                showOptionalCreditsAndExtraUsage: false,
                hidePersonalInfo: true,
                paceVisible: false,
                usesLiveSubtitle: false,
                now: Self.now))
            XCTAssertEqual(model.metrics.count, 1)
            XCTAssertEqual(model.metrics.first?.resetText, expected)
            for dark in [false, true] {
                let view = AnyView(UsageMenuCardUsageSectionView(
                    model: model,
                    layoutModel: model,
                    showBottomDivider: false,
                    bottomPadding: 12,
                    width: Self.width)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.accessibilityEnabled, true)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let stem = "reset-label-\(style.rawValue)-\(dark ? "dark" : "light")"
                let png = try XCTUnwrap(Self.pngData(hosting: hosting))
                try png.write(to: directory.appendingPathComponent("\(stem).png"))
                let accessibility = Self.accessibilityText(hosting)
                XCTAssertTrue(accessibility.contains(expected), accessibility)
                try accessibility.write(
                    to: directory.appendingPathComponent("\(stem)-accessibility.txt"),
                    atomically: true,
                    encoding: .utf8)
            }
        }
    }

    fileprivate static func pngDataWithWindow(hosting: NSHostingView<AnyView>) -> Data? {
        // Native List rows need a window to materialize, but it never needs to be ordered onscreen.
        let size = hosting.fittingSize
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = hosting.appearance
        window.contentView = hosting
        defer {
            window.contentView = nil
            window.close()
        }
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        return representation.representation(using: .png, properties: [:])
    }
}
