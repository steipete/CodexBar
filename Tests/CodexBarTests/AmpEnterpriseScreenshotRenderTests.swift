import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Renders the Amp enterprise menu card from a stub `amp` CLI, so the proof image carries no real spend.
@MainActor
final class AmpEnterpriseScreenshotRenderTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_795_032_000) // 2026-11-18T20:00:00Z
    private static let days: [(day: Int, tokens: Int, cost: Double)] = [
        (5, 1_840_000, 2.10), (6, 3_120_000, 3.85), (9, 2_460_000, 2.95), (10, 5_930_000, 7.40),
        (11, 4_210_000, 5.15), (12, 7_380_000, 9.60), (13, 1_150_000, 1.35), (16, 6_540_000, 8.20),
        (17, 8_910_000, 11.75), (18, 3_670_000, 4.30),
    ]

    func test_enterpriseCardShowsCostAndTokenHistory() async throws {
        let model = try await Self.model()
        let dashboard = try XCTUnwrap(model.inlineUsageDashboard)
        XCTAssertEqual(dashboard.kpis.map(\.title), ["Today", "30d", "Latest tokens", "30d tokens"])
        XCTAssertEqual(dashboard.kpis.map(\.value), ["$4.30", "$56.65", "3.7M", "45M"])
        XCTAssertEqual(dashboard.points.count(where: { ($0.value ?? 0) > 0 }), Self.days.count)
        XCTAssertTrue(dashboard.detailLines.contains("Top model: Example Large"))
        // Amp's figures are billed amounts, so the card must not call them a local-log estimate.
        XCTAssertEqual(dashboard.detailLines.last, "Recorded cost reported by Amp")
    }

    func test_renderSyntheticEnterpriseCard() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_AMP_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_AMP_SCREENSHOT_DIR to render the synthetic Amp enterprise card.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = try await Self.model()
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            for (name, scheme, appearance) in [
                ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua),
                ("light", ColorScheme.light, NSAppearance.Name.aqua),
            ] {
                let view = AnyView(UsageMenuCardView(model: model, width: 360)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.colorScheme, scheme)
                    .environment(\.displayScale, 2)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: appearance)
                try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                    .write(to: directory.appendingPathComponent("amp-enterprise-\(name).png"))
            }
        }
    }

    private static func model() async throws -> UsageMenuCardView.Model {
        let calendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")
        let snapshot = try await AmpCLIProbe(arguments: ["-c", self.script(), "amp", "usage"], calendar: calendar)
            .fetch(environment: ["AMP_CLI_PATH": "/bin/sh"], now: self.now)
        let usage = snapshot.toUsageSnapshot(now: self.now, calendar: calendar)
        return try UsageMenuCardView.Model.make(.init(
            provider: .amp,
            metadata: XCTUnwrap(ProviderDefaults.metadata[.amp]),
            snapshot: usage,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: usage.costUsage,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: usage.loginMethod(for: .amp)),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .absolute,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            usesLiveSubtitle: false,
            costUsageBucketCalendar: calendar,
            now: self.now))
    }

    /// A `/bin/sh` stand-in for `amp usage [--details --start … --end …]` with made-up figures.
    private static func script() -> String {
        func usd(_ value: Double) -> String {
            String(format: "$%.2f", value)
        }
        let rows = self.days.reversed().map { day in
            "| 2026-11-\(String(format: "%02d", day.day)) | $0.00 | \(usd(day.cost)) | \(usd(day.cost)) |"
        }.joined(separator: "\n")
        let totalTokens = self.days.map(\.tokens).reduce(0, +)
        let totalCost = self.days.map(\.cost).reduce(0, +)
        let branches = self.days.map { day -> String in
            let large = day.tokens * 4 / 5
            let small = day.tokens - large
            let largeRow = "\(large / 10) | \(large * 7 / 10) | \(large / 10) | \(large / 10) | \(large)"
            let smallRow = "\(small / 10) | \(small * 7 / 10) | \(small / 10) | \(small / 10) | \(small)"
            return """
            2026-11-\(String(format: "%02d", day.day))T00:00:00Z)
            cat <<'EOF'
            Total tokens: \(day.tokens)
            Total recorded cost: \(usd(day.cost))

            ## Models

            | Model | Uncached input | Cache read | Cache write | Output | Tokens | Recorded cost |
            | --- | ---: | ---: | ---: | ---: | ---: | ---: |
            | Example Large | \(largeRow) | \(usd(day.cost * 0.9)) |
            | Example Small | \(smallRow) | \(usd(day.cost * 0.1)) |
            EOF
            ;;
            """
        }.joined(separator: "\n")
        return """
        echo 'Signed in as member@example.com (member)'
        echo '**Workspace acme:** usage paid by your enterprise - https://ampcode.com/workspaces/acme'
        [ "$2" = "--details" ] || exit 0
        case "$4" in
        2026-10-20T00:00:00Z)
        cat <<'EOF'
        Range: 2026-10-20T00:00:00.000Z to 2026-11-19T00:00:00.000Z (end exclusive)
        Total tokens: \(totalTokens)
        Total recorded cost: \(usd(totalCost))

        ## Daily Recorded Cost

        | Date (UTC) | Covered | Paid | Total |
        | --- | ---: | ---: | ---: |
        \(rows)
        EOF
        ;;
        \(branches)
        *) exit 6 ;;
        esac
        """
    }
}
