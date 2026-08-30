import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

/// Developer tool, skipped by default: renders a provider card with the pace
/// stripe and forecast text shown and hidden, for documentation and PR review.
///
/// Run with:
///   CODEXBAR_PACE_SCREENSHOT_DIR=~/Downloads swift test --filter PaceVisibilityScreenshotRenderTests
@MainActor
final class PaceVisibilityScreenshotRenderTests: XCTestCase {
    private static let width: CGFloat = 320
    private static let now = Date(timeIntervalSince1970: 1_782_000_000)

    func test_renderPaceVisibilityScreenshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_PACE_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_PACE_SCREENSHOT_DIR to render pace visibility screenshots.")
        }
        let expanded = NSString(string: dir).expandingTildeInPath
        let directory = URL(fileURLWithPath: expanded, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (name, paceVisible) in [("pace-on-before", true), ("pace-off-after", false)] {
            let model = UsageMenuCardView.Model.make(Self.input(paceVisible: paceVisible))
            let view = AnyView(UsageMenuCardView(model: model, width: Self.width)
                .padding(12)
                .background(Color(nsColor: .windowBackgroundColor)))
            let data = try XCTUnwrap(Self.pngData(for: view), "render failed for \(name)")
            let url = directory.appendingPathComponent("codexbar-\(name).png")
            try data.write(to: url, options: .atomic)
            print("Wrote \(url.path)")
        }
    }

    func test_renderOpenCodeGoEstimateScreenshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_OPENCODEGO_PACE_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_OPENCODEGO_PACE_SCREENSHOT_DIR to render local quota estimate screenshots.")
        }
        let directory = URL(fileURLWithPath: NSString(string: dir).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance, scheme) in [
            ("light", NSAppearance.Name.aqua, ColorScheme.light),
            ("dark", NSAppearance.Name.darkAqua, ColorScheme.dark),
        ] {
            let model = UsageMenuCardView.Model.make(OpenCodeGoPaceTestSupport.input(confidence: .estimated))
            let view = AnyView(UsageMenuCardView(model: model, width: Self.width)
                .padding(12)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme))
            let data = try XCTUnwrap(Self.pngData(for: view, appearance: appearance))
            try data.write(to: directory.appendingPathComponent("opencodego-estimated-\(name).png"), options: .atomic)
        }
    }

    /// A Claude account running ahead of the sustainable rate, so the stripe and
    /// the forecast text both have something to render.
    private static func input(paceVisible: Bool) -> UsageMenuCardView.Model.Input {
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 61,
                windowMinutes: 300,
                resetsAt: Self.now.addingTimeInterval(3 * 3600 + 12 * 60),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 44,
                windowMinutes: 10080,
                resetsAt: Self.now.addingTimeInterval(4 * 86400 + 22 * 3600),
                resetDescription: nil),
            updatedAt: Self.now,
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "you@example.com",
                accountOrganization: nil,
                loginMethod: "Max 5x"))
        return .init(
            provider: .claude,
            metadata: ProviderDefaults.metadata[.claude]!,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "you@example.com", plan: "Max 5x"),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            paceVisible: paceVisible,
            now: Self.now)
    }

    private static func pngData(for view: AnyView, appearance: NSAppearance.Name = .darkAqua) -> Data? {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance)
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return nil }
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        else { return nil }
        representation.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: representation) else { return nil }
        hosting.displayIgnoringOpacity(hosting.bounds, in: context)
        return representation.representation(using: .png, properties: [:])
    }
}
