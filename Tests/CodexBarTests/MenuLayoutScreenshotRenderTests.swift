import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

/// Developer tool, skipped by default: renders the stacked (before) and compact
/// (after) claude-swap multi-account menu layouts to PNGs for documentation.
///
/// Run with:
///   CODEXBAR_SCREENSHOT_DIR=docs/screenshots swift test --filter MenuLayoutScreenshotRenderTests
@MainActor
final class MenuLayoutScreenshotRenderTests: XCTestCase {
    private static let width: CGFloat = 320
    private static let now = Date(timeIntervalSince1970: 1_782_000_000)

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
