import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

@MainActor
final class V0ScreenshotRenderTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_789_992_000)

    func test_sparseBillingKeepsOnlyKnownQuota() async throws {
        let snapshot = try await Self.snapshot(sparse: true)
        XCTAssertNil(snapshot.primary)
        XCTAssertEqual(snapshot.secondary?.usedPercent, 20)
        let model = try Self.model(snapshot)
        XCTAssertTrue(model.providerDetails.flatMap(\.rows).contains {
            $0.label == "Billing remaining" && $0.value == "Unavailable"
        })
    }

    func test_renderSyntheticBillingCards() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_V0_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_V0_SCREENSHOT_DIR to render synthetic v0 cards")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for sparse in [false, true] {
            let model = try await Self.model(Self.snapshot(sparse: sparse))
            try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
                let view = AnyView(UsageMenuCardView(model: model, width: 360)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.colorScheme, .light)
                    .environment(\.displayScale, 2)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: .aqua)
                let name = sparse ? "v0-sparse-billing.png" : "v0-token-billing.png"
                try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                    .write(to: directory.appendingPathComponent(name))
            }
        }
    }

    private static func snapshot(sparse: Bool) async throws -> UsageSnapshot {
        let runtime = try ProviderPluginRuntime(
            bundledPlugin: "v0",
            transport: ProviderHTTPTransportHandler { request in
                let billing = sparse
                    ? #"{"billingType":"legacy","data":{"limit":1000}}"#
                    : """
                    {"billingType":"token","data":{"balance":{"remaining":750,"total":1000},
                    "billingCycle":{"end":1800003600},"onDemand":{"balance":120}}}
                    """
                let body = request.url?.path == "/v1/user/billing" ? billing
                    : #"{"limit":100,"remaining":80,"reset":1800001800}"#
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (Data(body.utf8), response)
            })
        return try await runtime.fetchUsage(
            settings: ["V0_SCOPE": "project-demo"], secrets: ["V0_API_KEY": "fixture-key"], now: Self.now)
    }

    private static func model(_ snapshot: UsageSnapshot) throws -> UsageMenuCardView.Model {
        try UsageMenuCardView.Model.make(.init(
            provider: .v0,
            metadata: XCTUnwrap(ProviderDefaults.metadata[.v0]),
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: snapshot.loginMethod(for: .v0)),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .absolute,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            usesLiveSubtitle: false,
            now: self.now))
    }
}
