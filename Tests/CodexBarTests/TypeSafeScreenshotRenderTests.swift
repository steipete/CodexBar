import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

@MainActor
final class TypeSafeScreenshotRenderTests: XCTestCase {
    func test_billingUsesPayAsYouGoCardWithoutAnInventedQuota() async throws {
        let snapshot = try await TypeSafePluginTests.fetch(engine: .quickJS)
        let model = try Self.model(snapshot, costSummaryInline: true)
        let cost = try XCTUnwrap(model.providerCost)
        XCTAssertNil(cost.percentUsed)
        XCTAssertEqual(cost.spendLine, "September 2026: $0.01")
        XCTAssertEqual(cost.balanceLine, "Balance: $4.98")
        let rows = model.providerDetails.flatMap(\.rows)
        XCTAssertFalse(rows.contains { $0.label.hasPrefix("Spent") })
        XCTAssertTrue(rows.contains { $0.value.contains("4.98 of 5") })

        let defaultModel = try Self.model(snapshot)
        XCTAssertNil(defaultModel.providerCost)
        XCTAssertTrue(defaultModel.providerDetails.flatMap(\.rows)
            .contains { $0.label == "Spent (September 2026)" && $0.value == "$0.01" })
    }

    func test_renderSyntheticBillingCard() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_TYPESAFE_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_TYPESAFE_SCREENSHOT_DIR to render a synthetic TypeSafe card.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = try await TypeSafePluginTests.fetch(engine: .quickJS)
        let model = try Self.model(snapshot)
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let view = AnyView(UsageMenuCardView(model: model, width: 360)
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                .environment(\.colorScheme, .light)
                .environment(\.displayScale, 2)
                .background(Color(nsColor: .windowBackgroundColor)))
            let hosting = NSHostingView(rootView: view)
            hosting.appearance = NSAppearance(named: .aqua)
            try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                .write(to: directory.appendingPathComponent("typesafe-billing.png"))
        }
    }

    private static func model(
        _ snapshot: UsageSnapshot,
        costSummaryInline: Bool = false) throws -> UsageMenuCardView.Model
    {
        try UsageMenuCardView.Model.make(.init(
            provider: .typesafe,
            metadata: XCTUnwrap(ProviderDefaults.metadata[.typesafe]),
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: snapshot.loginMethod(for: .typesafe)),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .absolute,
            tokenCostUsageEnabled: false,
            costSummaryInlineEnabled: costSummaryInline,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            usesLiveSubtitle: false,
            now: TypeSafePluginTests.now))
    }
}
