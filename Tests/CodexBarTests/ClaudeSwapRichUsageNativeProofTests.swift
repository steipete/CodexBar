import AppKit
import CodexBarCore
import SwiftUI
import Vision
import XCTest
@testable import CodexBar

@MainActor
final class ClaudeSwapRichUsageNativeProofTests: XCTestCase {
    func test_renderActiveRepair() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_CLAUDE_SWAP_RICH_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_CLAUDE_SWAP_RICH_SCREENSHOT_DIR to capture synthetic account repair.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await ClaudeSwapRichUsageFixture.withFixture(activeNeedsRepair: true) { fixture in
            XCTAssertEqual(fixture.arguments, "--list\n--json\n")
            let model = try fixture.model(for: "1")
            XCTAssertEqual(model.planText, L("Re-authenticate"))
            for dark in [false, true] {
                let view = UsageMenuCardView(model: model, width: 340, planAction: {})
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .background(Color(nsColor: NSColor(calibratedWhite: dark ? 0.12 : 1, alpha: 1)))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let png = try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                try png.write(to: directory.appendingPathComponent("claude-swap-repair-\(dark ? "dark" : "light").png"))
                let text = try Self.visibleText(in: png)
                XCTAssertTrue(text.contains("Re-authenticate"), text)
                XCTAssertTrue(text.contains("Showing last-known usage captured 1 hour ago."), text)
            }
        }
    }

    func test_renderAccountCards() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_CLAUDE_SWAP_RICH_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_CLAUDE_SWAP_RICH_SCREENSHOT_DIR to capture synthetic account cards.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await ClaudeSwapRichUsageFixture.withFixture { fixture in
            XCTAssertEqual(fixture.arguments, "--list\n--json\n")
            XCTAssertEqual(fixture.accounts.count, 4)
            var observations: [[String: Any]] = []
            for (name, dark, privacy, highlighted) in [
                ("light", false, false, false),
                ("dark", true, false, false),
                ("privacy", false, true, false),
                ("highlighted", false, false, true),
            ] {
                let models = try fixture.accounts
                    .map { try fixture.model(for: $0.id.opaqueID, hidePersonalInfo: privacy) }
                if privacy {
                    XCTAssertEqual(models.map(\.email), ["Account 1", "Account 2", "Account 3", "Account 4"])
                }
                let background = highlighted
                    ? NSColor.selectedContentBackgroundColor
                    : NSColor(calibratedWhite: dark ? 0.12 : 1, alpha: 1)
                let view = VStack(spacing: 0) {
                    ForEach(Array(models.enumerated()), id: \.offset) { index, model in
                        UsageMenuCardView(
                            model: model,
                            width: 340,
                            planAction: fixture.accounts[index].canActivate ? {} : nil)
                        Divider()
                    }
                }
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.menuItemHighlighted, highlighted)
                .background(Color(nsColor: background))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let png = try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                try png.write(to: directory.appendingPathComponent("claude-swap-\(name).png"))
                let text = try Self.visibleText(in: png)
                XCTAssertEqual(text.components(separatedBy: "Showing last-known usage captured 1 hour ago.").count, 4)
                let compact = AccountMenuLayoutPlanner.plan(accounts: fixture.accounts).rows.compactMap { item ->
                    MenuCardCompactAccountRowView.Model? in
                    guard case let .compact(row) = item else { return nil }
                    let account = fixture.accounts.first { $0.id == row.accountID }
                    return MenuCardCompactAccountRowView.Model(
                        row: row,
                        resetTimeDisplayStyle: .countdown,
                        hidePersonalInfo: privacy,
                        privacyOrdinal: account.flatMap { ClaudeSwapAccountMenuDisplay.privacyOrdinal(for: $0) },
                        now: ClaudeSwapRichUsageFixture.now)
                }
                if privacy {
                    XCTAssertEqual(Set(compact.map(\.label)), ["Account 2", "Account 3", "Account 4"])
                }
                let compactView = VStack(spacing: 0) {
                    ForEach(Array(compact.enumerated()), id: \.offset) { _, model in
                        MenuCardCompactAccountRowView(
                            model: model,
                            progressColor: UsageMenuCardView.Model.progressColor(for: .claude),
                            width: 340)
                    }
                }
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.menuItemHighlighted, highlighted)
                .background(Color(nsColor: background))
                let compactHosting = NSHostingView(rootView: compactView)
                compactHosting.appearance = hosting.appearance
                let compactPNG = try XCTUnwrap(MenuLayoutScreenshotRenderTests
                    .pngDataWithWindow(hosting: compactHosting))
                try compactPNG.write(to: directory.appendingPathComponent("claude-swap-compact-\(name).png"))
                observations.append([
                    "appearance": name,
                    "cards": models.map { model -> [String: Any] in
                        [
                            "label": model.email, "subtitle": model.subtitleText,
                            "lastKnownUsage": model.lastKnownUsageText ?? "",
                            "percentages": model.metrics.map(\.percent),
                            "hasSpend": model.providerCost != nil,
                        ]
                    },
                    "compact": compact.map { model -> [String: Any] in
                        ["label": model.label, "details": model.detailLines]
                    },
                ])
            }
            try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("observations.json"))
        }
    }

    private static func visibleText(in png: Data) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(data: png).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}
