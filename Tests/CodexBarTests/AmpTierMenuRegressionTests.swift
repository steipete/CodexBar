import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class AmpTierMenuRegressionTests: XCTestCase {
    func test_tierOutputPreservesBothPoolsThroughMenuProjection() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-16T12:00:00Z"))
        let output = """
        Amp Megawatt Tier: agent usage $18.57 of $20 remaining (93%), \
        orb usage 732.8h of 750h a1.small orb hours remaining (98%) - \
        period 2026-09-13 to 2026-10-13, resets upon renewal in 27 days
        Individual credits: $20 remaining
        """
        let snapshot = try AmpUsageParser.parse(displayText: output, now: now).toUsageSnapshot(now: now)
        let model = try UsageMenuCardView.Model.make(.init(
            provider: .amp,
            metadata: XCTUnwrap(ProviderDefaults.metadata[.amp]),
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
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            paceVisible: true,
            usesLiveSubtitle: false,
            now: now))

        if let path = ProcessInfo.processInfo.environment["CODEXBAR_AMP_TIER_PROOF_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for dark in [false, true] {
                let view = AnyView(UsageMenuCardView(model: model, width: 320)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.displayScale, 2)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                    .write(to: directory.appendingPathComponent("amp-tier-\(dark ? "dark" : "light").png"))
            }
        }

        XCTAssertEqual(model.metrics.map(\.title), ["Agent usage", "Orb usage"])
        XCTAssertEqual(try XCTUnwrap(snapshot.primary?.usedPercent), 7.15, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snapshot.secondary?.usedPercent), 2.2933333333, accuracy: 0.0001)
        XCTAssertEqual(snapshot.primary?.windowMinutes, 30 * 24 * 60)
        XCTAssertEqual(model.providerDetails.map(\.title), ["Monthly allowances", "Credits"])
        XCTAssertEqual(model.providerDetails.first?.rows.map(\.value), ["$18.57", "732h"])
        XCTAssertEqual(model.providerDetails.last?.rows.first?.value, "$20.00")
    }
}
