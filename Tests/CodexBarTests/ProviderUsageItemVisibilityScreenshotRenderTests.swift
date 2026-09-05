import AppKit
import CodexBarCore
import SwiftUI
import XCTest
@testable import CodexBar

/// Developer tool, skipped by default: renders the per-provider usage selector and the resulting
/// shared provider-card/Overview projection with entirely synthetic data.
///
/// Run with:
///   CODEXBAR_USAGE_ITEMS_SCREENSHOT_DIR=.github/pr-proof \
///     swift test --filter ProviderUsageItemVisibilityScreenshotRenderTests
@MainActor
final class ProviderUsageItemVisibilityScreenshotRenderTests: XCTestCase {
    private static let cardWidth: CGFloat = 360

    func test_renderProviderUsageItemVisibilityProof() throws {
        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_USAGE_ITEMS_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set CODEXBAR_USAGE_ITEMS_SCREENSHOT_DIR to render the usage-item screenshot.")
        }
        let directory = URL(
            fileURLWithPath: NSString(string: dir).expandingTildeInPath,
            isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let rawModel = Self.codexModel()
        let hiddenIDs: Set<ProviderUsageItemID> = [
            .metric("primary"),
            .metric("codex-spark"),
            .metric("codex-spark-weekly"),
            .credits,
        ]
        let settings = testSettingsStore(
            suiteName: "ProviderUsageItemVisibilityScreenshotRenderTests",
            config: CodexBarConfig(providers: [
                ProviderConfig(
                    id: .codex,
                    enabled: true,
                    hiddenUsageItemIDs: hiddenIDs.map(\.rawValue).sorted()),
            ]))
        let filteredModel = rawModel.applyingUsageItemVisibility(hiddenItemIDs: hiddenIDs)

        let view = AnyView(VStack(alignment: .leading, spacing: 16) {
            Text("Codex display settings (synthetic data)")
                .font(.headline)

            Form {
                ProviderUsageItemVisibilitySettingsView(
                    provider: .codex,
                    settings: settings,
                    items: rawModel.usageItemDescriptors)
            }
            .formStyle(.grouped)
            .frame(width: 480, height: 330)

            Text("Provider card and Overview result")
                .font(.headline)

            UsageMenuCardView(model: filteredModel, width: Self.cardWidth)
                .padding(12)
                .frame(width: Self.cardWidth + 24)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(20)
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor)))

        let data = try XCTUnwrap(Self.pngData(for: view), "usage-item proof render failed")
        let url = directory.appendingPathComponent("provider-usage-item-visibility.png")
        try data.write(to: url, options: .atomic)
        print("Wrote \(url.path)")
    }

    private static func codexModel() -> UsageMenuCardView.Model {
        let metrics = [
            self.metric(id: "primary", title: "5-hour", percent: 18),
            self.metric(id: "secondary", title: "Weekly", percent: 5),
            self.metric(id: "codex-spark", title: "Codex Spark 5-hour", percent: 0),
            self.metric(id: "codex-spark-weekly", title: "Codex Spark Weekly", percent: 0),
        ]
        return UsageMenuCardView.Model(
            provider: .codex,
            providerName: "Codex",
            email: "",
            subtitleText: "Updated just now",
            subtitleStyle: .info,
            planText: "Pro 20x",
            metrics: metrics,
            usageNotes: [],
            openAIAPIUsage: nil,
            inlineUsageDashboard: nil,
            creditsText: "$12.34 remaining",
            creditsRemaining: 12.34,
            creditsProgressPercent: 50,
            creditsScaleText: "$25",
            creditsHintText: nil,
            creditsHintCopyText: nil,
            codexResetCredits: CodexResetCreditsPresentation(
                text: "1 available",
                items: [.init(expiryText: "Expires Sep 20", compactExpiryText: "Sep 20")]),
            providerCost: nil,
            tokenUsage: nil,
            placeholder: nil,
            progressColor: .cyan)
    }

    private static func metric(
        id: String,
        title: String,
        percent: Double) -> UsageMenuCardView.Model.Metric
    {
        .init(
            id: id,
            title: title,
            percent: percent,
            percentStyle: .used,
            resetText: id == "secondary" ? "Resets Aug 30" : nil,
            detailText: nil,
            detailLeftText: nil,
            detailRightText: nil,
            pacePercent: nil,
            paceOnTop: true)
    }

    private static func pngData(for view: AnyView) -> Data? {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .aqua)
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return nil }
        hosting.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        return representation.representation(using: .png, properties: [:])
    }
}
