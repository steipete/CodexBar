import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

@MainActor
final class HelmcodeScreenshotRenderTests: XCTestCase {
    func test_modelKeepsQuotaAndBalanceWithoutUnconfirmedPremiumTiers() async throws {
        let snapshot = try await HelmcodePluginTests.fetch(engine: .quickJS, billing: "{}").usage
        let model = try Self.model(snapshot)
        XCTAssertEqual(model.metrics.count, 4)
        XCTAssertNotNil(model.providerCost)
        XCTAssertTrue(model.metrics.first?.detailText?.contains("helm-monthly") == true)
    }

    func test_renderSyntheticPremiumEligibilityComparison() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_HELMCODE_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_HELMCODE_SCREENSHOT_DIR to render synthetic Helmcode cards.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Reconstruct the proposal's missing-billing output, which exposed all premium tiers.
        let before = try await HelmcodePluginTests.fetch(
            engine: .quickJS, billing: HelmcodePluginTests.fixture("billing-premium")).usage
        let after = try await HelmcodePluginTests.fetch(engine: .quickJS, billing: "{}").usage
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            for (name, snapshot) in [("before", before), ("after", after)] {
                let view = try AnyView(UsageMenuCardView(model: Self.model(snapshot), width: 360)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.colorScheme, .light)
                    .environment(\.displayScale, 2)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: .aqua)
                try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                    .write(to: directory.appendingPathComponent("helmcode-\(name).png"))
            }
        }
    }

    private static func model(_ snapshot: UsageSnapshot) throws -> UsageMenuCardView.Model {
        try UsageMenuCardView.Model.make(.init(
            provider: .helmcode,
            metadata: XCTUnwrap(ProviderDefaults.metadata[.helmcode]),
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .absolute,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            usesLiveSubtitle: false,
            now: HelmcodePluginTests.now))
    }
}
