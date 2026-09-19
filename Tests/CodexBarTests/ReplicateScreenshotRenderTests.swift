import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

@MainActor
final class ReplicateScreenshotRenderTests: XCTestCase {
    func test_billingUsesDetailsWithoutAnInventedQuota() async throws {
        let snapshot = try await ReplicatePluginTests.fetch(engine: .quickJS)
        let model = try Self.model(snapshot)
        XCTAssertNil(model.providerCost)
        XCTAssertTrue(model.providerDetails.flatMap(\.rows)
            .contains { $0.label == "Spent this month" && $0.value == "$12.40" })
    }

    func test_renderSyntheticBillingCards() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_REPLICATE_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_REPLICATE_SCREENSHOT_DIR to render synthetic Replicate cards.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let after = try await ReplicatePluginTests.fetch(engine: .quickJS)
        // Reconstructed synthetic output of the proposal's zero-percent placeholder.
        let before = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$12.40 spent this month · $80.00 credit"),
            secondary: nil,
            updatedAt: ReplicatePluginTests.now)
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            for (name, snapshot) in [("before", before), ("after", after)] {
                let model = try Self.model(snapshot)
                let view = AnyView(UsageMenuCardView(model: model, width: 360)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.colorScheme, .light)
                    .environment(\.displayScale, 2)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: .aqua)
                try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                    .write(to: directory.appendingPathComponent("replicate-\(name).png"))
            }
        }
    }

    private static func model(_ snapshot: UsageSnapshot) throws -> UsageMenuCardView.Model {
        try UsageMenuCardView.Model.make(.init(
            provider: .replicate,
            metadata: XCTUnwrap(ProviderDefaults.metadata[.replicate]),
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: snapshot.loginMethod(for: .replicate)),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .absolute,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            usesLiveSubtitle: false,
            now: ReplicatePluginTests.now))
    }
}
