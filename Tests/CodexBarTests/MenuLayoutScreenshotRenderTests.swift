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
