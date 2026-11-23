import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Synthetic menu-card proof from the redacted fixture, skipped by default. No app launch, account,
/// provider request, or credential access is involved.
@MainActor
final class ClaudeWeeklyProductBreakdownRenderTests: XCTestCase {
    func test_renderWeeklyProductBreakdown() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_CLAUDE_PRODUCT_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_CLAUDE_PRODUCT_PROOF_DIR for synthetic Claude product breakdown proof")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_795_468_709)
        let after = try ClaudeWeeklyProductBreakdownTests.snapshot(ClaudeWeeklyProductBreakdownTests.fixture)
        let before = after.replacing(details: .value([]))
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            for (stage, snapshot) in [("before", before), ("after", after)] {
                let model = try ClaudeWeeklyProductBreakdownTests.menuModel(snapshot: snapshot, now: now)
                for dark in [false, true] {
                    let view = AnyView(UsageMenuCardView(model: model, width: 320)
                        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .environment(\.displayScale, 2)
                        .background(Color(nsColor: .windowBackgroundColor)))
                    let hosting = NSHostingView(rootView: view)
                    hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let name = "claude-product-\(stage)-\(dark ? "dark" : "light").png"
                    try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                        .write(to: directory.appendingPathComponent(name))
                }
            }
        }
    }
}
