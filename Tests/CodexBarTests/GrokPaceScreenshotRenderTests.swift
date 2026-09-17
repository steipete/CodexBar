import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Synthetic menu-card proof, skipped by default. The before model reproduces the old
/// durationless normalization; the after model uses the production proxy parser and mapper.
/// No app launch, account configuration, provider request, or credential access is involved.
@MainActor
final class GrokPaceScreenshotRenderTests: XCTestCase {
    func test_renderMeasuredProxyPace() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_GROK_PACE_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_GROK_PACE_PROOF_DIR to render synthetic Grok pacing proof.")
        }
        let directory = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            for hoursUntilReset in [30, 6] {
                let reset = try XCTUnwrap(ISO8601DateParser.parse("2026-08-13T12:00:00.123456+00:00"))
                let now = reset.addingTimeInterval(-Double(hoursUntilReset) * 3600)
                let after = try Self.snapshot(now: now)
                let measured = try XCTUnwrap(after.primary)
                let before = UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: measured.usedPercent,
                        windowMinutes: nil,
                        resetsAt: measured.resetsAt,
                        resetDescription: measured.resetDescription),
                    secondary: nil,
                    updatedAt: after.updatedAt,
                    identity: after.identity)

                for (phase, snapshot) in [("before", before), ("after", after)] {
                    let model = try Self.model(snapshot: snapshot, now: now)
                    let metric = try XCTUnwrap(model.metrics.first { $0.id == "primary" })
                    XCTAssertEqual(metric.title, "Weekly")
                    XCTAssertEqual(metric.percent, 10)
                    XCTAssertEqual(metric.pacePercent != nil, phase == "after")
                    XCTAssertEqual(metric.detailLeftText != nil, phase == "after")
                    XCTAssertEqual(metric.detailRightText != nil, phase == "after")

                    for (appearance, scheme, theme) in [
                        (NSAppearance.Name.aqua, ColorScheme.light, "light"),
                        (NSAppearance.Name.darkAqua, ColorScheme.dark, "dark"),
                    ] {
                        let view = AnyView(UsageMenuCardView(model: model, width: 320)
                            .padding(12)
                            .background(Color(nsColor: .windowBackgroundColor))
                            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                            .environment(\.colorScheme, scheme))
                        let hosting = NSHostingView(rootView: view)
                        hosting.appearance = NSAppearance(named: appearance)
                        let png = try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                        let filename = "grok-proxy-\(hoursUntilReset)h-\(phase)-\(theme).png"
                        try png.write(to: directory.appendingPathComponent(filename), options: .atomic)
                    }
                }
            }
        }
    }

    private static func snapshot(now: Date) throws -> UsageSnapshot {
        let proxy = try GrokCreditsProxyFetcher.parseSnapshot(Data("""
        {
          "config": {
            "creditUsagePercent": 90,
            "currentPeriod": {
              "start": "2026-08-06T12:00:00.123456+00:00",
              "end": "2026-08-13T12:00:00.123456+00:00"
            }
          }
        }
        """.utf8), now: now)
        return GrokUsageSnapshot(
            billing: nil,
            webBilling: proxy,
            credentials: nil,
            localSummary: nil,
            cliVersion: nil,
            updatedAt: now).toUsageSnapshot()
    }

    private static func model(snapshot: UsageSnapshot, now: Date) throws -> UsageMenuCardView.Model {
        let metadata = try XCTUnwrap(ProviderDefaults.metadata[.grok])
        return UsageMenuCardView.Model.make(.init(
            provider: .grok,
            metadata: metadata,
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
    }
}
