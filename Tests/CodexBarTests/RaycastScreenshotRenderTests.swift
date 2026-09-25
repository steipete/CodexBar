import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

/// Opt-in synthetic Raycast cards for PR proof.
///
///     CODEXBAR_RAYCAST_SCREENSHOT_DIR=/tmp/raycast-cards swift test --filter RaycastScreenshotRenderTests
@MainActor
final class RaycastScreenshotRenderTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_790_251_200)

    func test_renderSyntheticCreditCards() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_RAYCAST_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_RAYCAST_SCREENSHOT_DIR to render synthetic Raycast cards.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let remaining = try await Self.fetch(#"""
        {
          "remaining_balance_credits": "125",
          "total_balance_credits": "500",
          "next_credits_at": "2026-10-18T00:00:00.000Z",
          "funding_subscription": {"tier": "pro", "status": "active"}
        }
        """#)

        let cards: [(String, Bool, ResetTimeDisplayStyle)] = [
            ("remaining-left", false, .countdown),
            ("remaining-used", true, .absolute),
        ]

        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            for (name, showUsed, resetStyle) in cards {
                let model = try Self.model(remaining, showUsed: showUsed, resetStyle: resetStyle)
                let view = AnyView(UsageMenuCardView(model: model, width: 360)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.colorScheme, .light)
                    .environment(\.displayScale, 2)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: .aqua)
                try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                    .write(to: directory.appendingPathComponent("raycast-\(name).png"))
            }
        }
    }

    private static func fetch(_ body: String) async throws -> UsageSnapshot {
        let runtime = try BundledPluginTestSupport.runtime(
            "raycast",
            engine: .quickJS,
            transport: ProviderHTTPTransportHandler { request in
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]))
                return (Data(body.utf8), response)
            })
        return try await runtime.fetchUsage(
            now: Self.now,
            timeZone: TimeZone(identifier: "UTC") ?? .gmt,
            cookieResolver: { _, _ in
                "__raycast_session=fixture-session; csrf_token=fixture-csrf"
            })
    }

    private static func model(
        _ snapshot: UsageSnapshot,
        showUsed: Bool,
        resetStyle: ResetTimeDisplayStyle) throws -> UsageMenuCardView.Model
    {
        try UsageMenuCardView.Model.make(.init(
            provider: .raycast,
            metadata: XCTUnwrap(ProviderDefaults.metadata[.raycast]),
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: snapshot.loginMethod(for: .raycast)),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: showUsed,
            resetTimeDisplayStyle: resetStyle,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            usesLiveSubtitle: false,
            now: self.now))
    }
}
