import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Renders the real card with synthetic spend, credit, and allowance data; no network or credential access.
@MainActor
final class MistralAllowanceMenuScreenshotRenderTests: XCTestCase {
    func test_includedAPIAndMonthlyPlanRenderThroughSharedDescriptor() throws {
        let now = try XCTUnwrap(ISO8601DateParser.parse("2026-09-18T00:00:00Z"))
        let reset = try XCTUnwrap(ISO8601DateParser.parse("2026-10-01T00:00:00Z"))
        let base = MistralUsageSnapshot(
            totalCost: 7.25,
            currency: "EUR",
            currencySymbol: "€",
            totalInputTokens: 1000,
            totalOutputTokens: 500,
            totalCachedTokens: 0,
            modelCount: 2,
            credits: MistralCreditsSnapshot(
                walletAmount: 40, creditNotesAmount: 0, ongoingUsageBalance: 7.25, currency: "EUR"),
            startDate: nil,
            endDate: nil,
            updatedAt: now).toUsageSnapshot()
        let snapshot = MistralWebFetchStrategy.attachSubscriptionBudgets(to: base, budgets: MistralSubscriptionBudgets(
            api: MistralSubscriptionBudget(usagePercentage: 20, limit: 50, currencyCode: "EUR", resetsAt: reset),
            vibe: MistralSubscriptionBudget(usagePercentage: 25, limit: 100, currencyCode: "EUR", resetsAt: reset)))
        for (stage, usage) in [("before", base), ("after", snapshot)] {
            let model = try UsageMenuCardView.Model.make(.init(
                provider: .mistral,
                metadata: XCTUnwrap(ProviderDefaults.metadata[.mistral]),
                snapshot: usage,
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
                paceVisible: false,
                usesLiveSubtitle: false,
                now: now))
            if stage == "after" {
                let primary = try XCTUnwrap(model.metrics.first { $0.id == "primary" })
                XCTAssertEqual(primary.title, "Included API")
                XCTAssertEqual(primary.detailText, "€10.00 / €50.00 · €40.00 left")
            }
            guard let path = ProcessInfo.processInfo.environment["CODEXBAR_MISTRAL_ALLOWANCE_PROOF_DIR"]
            else { continue }
            guard ProcessInfo.processInfo.environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1" else {
                return XCTFail("Use isolated synthetic proof")
            }
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for dark in [false, true] {
                let view = AnyView(UsageMenuCardView(model: model, width: 360)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.displayScale, 2)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                    .write(to: directory.appendingPathComponent("\(stage)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
