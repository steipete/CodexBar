import AppKit
import SwiftUI
import Testing
import XCTest
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

@MainActor
struct VenicePresentationTests {
    static let now = Date(timeIntervalSince1970: 1_788_000_000)

    static func snapshot() throws -> UsageSnapshot {
        try VeniceWebUsageFetcher.snapshot(fromClaims: [
            "exp": self.now.timeIntervalSince1970 + 3600,
            "userType": "MAX",
            "veniceCredits": 40500,
            "bundledCreditsUsage": [
                "usedThisCycle": 30000, "monthlyRefillCredits": 22500,
                "availableCredits": 40000, "tierCap": 67500,
                "nextRefillAt": (self.now.timeIntervalSince1970 + 86400) * 1000,
            ],
        ], now: self.now)
    }

    static func model(snapshot: UsageSnapshot?, extras: Bool) throws -> UsageMenuCardView.Model {
        UsageMenuCardView.Model.make(.init(
            provider: .venice,
            metadata: VeniceProviderDescriptor.descriptor.metadata,
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
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: extras,
            hidePersonalInfo: true,
            usesLiveSubtitle: false,
            now: self.now))
    }

    @Test(arguments: [false, true])
    func `banked credits remain visible without an exhausted quota`(extras: Bool) throws {
        let snapshot = try Self.snapshot()
        let model = try Self.model(snapshot: snapshot, extras: extras)
        #expect(model.placeholder == nil)
        #expect(model.metrics.isEmpty)
        let rows = model.providerDetails.flatMap(\.rows)
        #expect(rows.first { $0.label == "Subscription credits available" }?.value == "40,000")
        let spending = try #require(rows.first { $0.label == "Used this cycle" })
        #expect(spending.value == "30,000")
        #expect(spending.secondaryValue == "Monthly refill: 22,500")
        #expect(spending.progress?.usedPercent == 30000.0 / 22500 * 100)
        #expect(snapshot.subscriptionRenewsAt == nil)
        let card = CLICardsRenderer.makeCard(CLICardBuildInput(
            provider: .venice,
            snapshot: snapshot,
            credits: nil,
            source: "web",
            status: nil,
            notes: [],
            useColor: false,
            resetStyle: .countdown,
            weeklyWorkDays: nil,
            now: Self.now))
        let output = CLICardsRenderer.render(cards: [card], failures: [], terminalWidth: 100, useColor: false)
        #expect(output.contains("40,000"))
        #expect(!output.contains("0% left"))
    }
}

@MainActor
final class VeniceNativeProofTests: XCTestCase {
    func test_renderSubscriptionCredits() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_VENICE_WEB_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_VENICE_WEB_PROOF_DIR for synthetic subscription proof")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = try VenicePresentationTests.snapshot()
        for (stage, usage) in [("before", nil), ("after", Optional(snapshot))] {
            let model = try VenicePresentationTests.model(snapshot: usage, extras: false)
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
