import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

@MainActor
final class LangdockScreenshotRenderTests: XCTestCase {
    func test_renderSyntheticUsageCards() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_LANGDOCK_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_LANGDOCK_PROOF_DIR to render synthetic Langdock cards.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sessionReset = ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))
        let weeklyReset = ISO8601DateFormatter().string(from: now.addingTimeInterval(3 * 24 * 3600))
        func snapshot(sessionEnabled: Bool, capturedAt: Date) throws -> UsageSnapshot {
            try LangdockUsageParser.parse(
                Data("""
                [{"result":{"data":{"json":{"hasIncludedUsageLimits":true,"planUsage":{
                  "sessionUsageLimitsEnabled":\(sessionEnabled),"sessionUsagePercent":23,
                  "sessionResetsAt":"\(sessionReset)","weeklyUsagePercent":54,
                  "weeklyResetsAt":"\(weeklyReset)"}}}}}]
                """.utf8),
                statusCode: 200,
                now: capturedAt)
        }
        let scenarios: [(String, UsageSnapshot, String?)] = try [
            ("active", snapshot(sessionEnabled: true, capturedAt: now), nil),
            ("weekly-only", snapshot(sessionEnabled: false, capturedAt: now), nil),
            (
                "stale", snapshot(sessionEnabled: true, capturedAt: now.addingTimeInterval(-900)),
                LangdockUsageError.httpStatus(503).localizedDescription),
        ]
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            for (name, snapshot, error) in scenarios {
                let model = try UsageMenuCardView.Model.make(.init(
                    provider: .langdock,
                    metadata: XCTUnwrap(ProviderDefaults.metadata[.langdock]),
                    snapshot: snapshot,
                    credits: nil,
                    creditsError: nil,
                    dashboardError: nil,
                    tokenSnapshot: nil,
                    tokenError: nil,
                    account: AccountInfo(email: nil, plan: nil),
                    lastKnownUsageCapturedAt: error == nil ? nil : snapshot.updatedAt,
                    isRefreshing: false,
                    lastError: error,
                    usageBarsShowUsed: true,
                    resetTimeDisplayStyle: .countdown,
                    tokenCostUsageEnabled: false,
                    showOptionalCreditsAndExtraUsage: false,
                    hidePersonalInfo: true,
                    usesLiveSubtitle: false,
                    now: now))
                let view = AnyView(UsageMenuCardView(model: model, width: 360)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.colorScheme, .light)
                    .environment(\.displayScale, 2)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: .aqua)
                try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                    .write(to: directory.appendingPathComponent("langdock-\(name).png"))
            }
        }
    }
}
