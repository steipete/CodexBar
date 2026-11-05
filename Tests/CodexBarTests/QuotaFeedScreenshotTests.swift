import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

/// Opt-in rendering with synthetic quota data; never reads an account, keychain, or live feed.
@MainActor
final class QuotaFeedScreenshotTests: XCTestCase {
    func test_renderSyntheticQuota() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_QUOTAFEED_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_QUOTAFEED_SCREENSHOT_DIR to render synthetic cards.")
        }
        let now = Date(timeIntervalSince1970: 1_767_268_800)
        let snapshot = try UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            providerCost: ProviderCostSnapshot(used: 25, limit: 100, currencyCode: "USD", updatedAt: now),
            details: [ProviderDetailSection(title: "Quota", rows: [
                .init(label: "Used", value: "25.00 USD"),
                .init(label: "Limit", value: "100.00 USD"),
                .init(label: "Remaining", value: "75.00 USD"),
            ])],
            updatedAt: now)
        let model = try UsageMenuCardView.Model.make(.init(
            provider: .quotafeed,
            metadata: XCTUnwrap(ProviderDefaults.metadata[.quotafeed]),
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .absolute,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            usesLiveSubtitle: false,
            now: now))
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, scheme, appearance) in [
            ("light", ColorScheme.light, NSAppearance.Name.aqua),
            ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua),
        ] {
            let view = AnyView(UsageMenuCardView(model: model, width: 360)
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                .environment(\.colorScheme, scheme)
                .environment(\.displayScale, 2)
                .background(Color(nsColor: .windowBackgroundColor)))
            let hosting = NSHostingView(rootView: view)
            hosting.appearance = NSAppearance(named: appearance)
            try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                .write(to: directory.appendingPathComponent("quota-feed-\(name).png"))
        }
    }
}
