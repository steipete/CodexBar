import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

/// Opt-in synthetic WorkBuddy cards for PR proof.
///
///     CODEXBAR_WORKBUDDY_SCREENSHOT_DIR=/tmp/workbuddy-cards swift test --filter WorkBuddyScreenshotRenderTests
@MainActor
final class WorkBuddyScreenshotRenderTests: XCTestCase {
    /// 2026-10-03T00:00:00Z
    private static let now = Date(timeIntervalSince1970: 1_790_985_600)

    func test_renderSyntheticCreditCards() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_WORKBUDDY_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_WORKBUDDY_SCREENSHOT_DIR to render synthetic WorkBuddy cards.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let snapshot = try await Self.fetch()
        let cards: [(String, Bool, ResetTimeDisplayStyle)] = [
            ("remaining-left", false, .countdown),
            ("remaining-used", true, .absolute),
        ]

        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            for (name, showUsed, resetStyle) in cards {
                let model = try Self.model(snapshot, showUsed: showUsed, resetStyle: resetStyle)
                let view = AnyView(UsageMenuCardView(model: model, width: 360)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.colorScheme, .light)
                    .environment(\.displayScale, 2)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: .aqua)
                try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                    .write(to: directory.appendingPathComponent("workbuddy-\(name).png"))
            }
        }
    }

    private static func fetch() async throws -> UsageSnapshot {
        let summary = #"""
        {"code":0,"msg":"OK","data":{"SubscriptionPackageName":"体验版","IsPaidUser":false,"Packages":[
          {"CycleTotalCapacity":"500","CycleRemainCapacity":"450","CycleFrozenCapacity":"0","CapacityUnit":"credits"}
        ]}}
        """#
        let free = #"""
        {"code":0,"msg":"OK","data":{"Accounts":[
          {"CapacityUnit":"credits","CycleStartTime":"2026-10-01 00:00:00","CycleEndTime":"2026-10-31 23:59:59"}
        ]}}
        """#
        let runtime = try BundledPluginTestSupport.runtime(
            "workbuddy",
            engine: .quickJS,
            transport: ProviderHTTPTransportHandler { request in
                let body = switch request.url?.path {
                case "/billing/meter/get-user-resource-summary": summary
                case "/billing/meter/get-user-resource-free-packages": free
                default: #"{"code":0,"msg":"OK","data":{"Accounts":[]}}"#
                }
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
            cookieSessionResolver: { _, _ in
                ProviderPluginCookieSession(
                    header: "session=fixture-session",
                    source: "Fixture",
                    origin: "https://www.workbuddy.cn")
            },
            cookieSessionValidator: { _, _ in })
    }

    private static func model(
        _ snapshot: UsageSnapshot,
        showUsed: Bool,
        resetStyle: ResetTimeDisplayStyle) throws -> UsageMenuCardView.Model
    {
        try UsageMenuCardView.Model.make(.init(
            provider: .workbuddy,
            metadata: XCTUnwrap(ProviderDefaults.metadata[.workbuddy]),
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: snapshot.loginMethod(for: .workbuddy)),
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
