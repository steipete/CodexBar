import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

@MainActor
final class HuggingFaceScreenshotRenderTests: XCTestCase {
    func test_includedCreditSpendDoesNotBecomeExtraUsage() async throws {
        let snapshot = try await HuggingFacePluginTests.fetch(engine: .quickJS)
        let model = try Self.model(snapshot)
        XCTAssertNil(model.providerCost)
        XCTAssertTrue(model.providerDetails.flatMap(\.rows)
            .contains { $0.label == "Billable usage" && $0.value == "$0.45" })
    }

    func test_renderSyntheticBillingCards() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_HF_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_HF_SCREENSHOT_DIR to render synthetic Hugging Face cards.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let after = try await HuggingFacePluginTests.fetch(
            billing: #"{"usage":{"inferenceProviders":{"usedNanoUsd":300000000,"includedNanoUsd":0}}}"#,
            engine: .quickJS,
            optionalStatus: 503)
        let full = try await HuggingFacePluginTests.fetch(engine: .quickJS)
        let wallet = try await HuggingFaceWalletPluginTests.fetch(engine: .quickJS)
        // Golden output of the original Swift proposal when spend exists without a quota denominator.
        let before = try UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 43200, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            details: [ProviderDetailSection(title: "Inference Providers", rows: [
                .init(label: "Spend", value: "$0.30"),
            ])],
            updatedAt: HuggingFacePluginTests.now,
            identity: ProviderIdentitySnapshot(
                providerID: .huggingface, accountEmail: nil, accountOrganization: nil, loginMethod: "API token"),
            dataConfidence: .exact)
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            for (name, snapshot) in [
                ("before-no-quota", before), ("after-no-quota", after), ("after-full", full),
                ("wallet-before", full), ("wallet-after", wallet),
            ] {
                let model = try Self.model(snapshot)
                let view = AnyView(UsageMenuCardView(model: model, width: 360)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.colorScheme, .light)
                    .environment(\.displayScale, 2)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: .aqua)
                try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                    .write(to: directory.appendingPathComponent("huggingface-\(name).png"))
            }
        }
    }

    private static func model(_ snapshot: UsageSnapshot) throws -> UsageMenuCardView.Model {
        try UsageMenuCardView.Model.make(.init(
            provider: .huggingface,
            metadata: XCTUnwrap(ProviderDefaults.metadata[.huggingface]),
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: snapshot.loginMethod(for: .huggingface)),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .absolute,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            usesLiveSubtitle: false,
            now: HuggingFacePluginTests.now))
    }
}
