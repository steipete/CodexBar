import AppKit
import CodexBarCore
import SwiftUI
import WidgetKit
import XCTest
@testable import CodexBarWidget

/// Opt-in, synthetic rendering proof for each production widget that exposes the share route.
@MainActor
final class WidgetShareOverviewNativeProofTests: XCTestCase {
    private struct Canvas {
        let name: String
        let size: CGSize
        let content: AnyView
    }

    func test_shareOverviewWidgetsRenderInsideSyntheticDesktopMargins() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["CODEXBAR_WIDGET_SHARE_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_WIDGET_SHARE_PROOF_DIR to render the synthetic widget proof.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        guard environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1",
              NSHomeDirectory().hasPrefix(output.deletingLastPathComponent().path + "/")
        else { return XCTFail("Use contained home plus credential and session isolation.") }

        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let snapshot = WidgetPreviewData.snapshot()
        let entry = CodexBarWidgetEntry(date: Date(), provider: .codex, snapshot: snapshot)
        let worstCaseEntry = try XCTUnwrap(snapshot.entries.first { $0.provider == .codex })
        XCTAssertEqual(WidgetUsageRow.rows(for: worstCaseEntry).count, 2)
        XCTAssertNotNil(worstCaseEntry.codeReviewRemainingPercent)
        let compactEntry = CodexBarCompactEntry(
            date: Date(),
            provider: .codex,
            metric: .todayCost,
            snapshot: snapshot)
        let switcherEntry = CodexBarSwitcherEntry(
            date: Date(),
            provider: .codex,
            availableProviders: [.codex, .claude, .cursor],
            snapshot: snapshot)
        let small = CGSize(width: 160, height: 160)
        let medium = CGSize(width: 360, height: 160)
        let large = CGSize(width: 360, height: 380)
        let canvases: [Canvas] = [
            self.canvas("usage-small", small, CodexBarUsageWidgetView(entry: entry).content(for: .systemSmall)),
            self.canvas("usage-medium", medium, CodexBarUsageWidgetView(entry: entry).content(for: .systemMedium)),
            self.canvas("usage-large", large, CodexBarUsageWidgetView(entry: entry).content(for: .systemLarge)),
            self.canvas("compact-small", small, CodexBarCompactWidgetView(entry: compactEntry)),
            self.canvas(
                "switcher-small",
                small,
                CodexBarSwitcherWidgetView(entry: switcherEntry).content(for: .systemSmall)),
            self.canvas(
                "switcher-medium",
                medium,
                CodexBarSwitcherWidgetView(entry: switcherEntry).content(for: .systemMedium)),
            self.canvas(
                "switcher-large",
                large,
                CodexBarSwitcherWidgetView(entry: switcherEntry).content(for: .systemLarge)),
            self.canvas("history-medium", medium, CodexBarHistoryWidgetView(entry: entry).content(for: .systemMedium)),
            self.canvas("history-large", large, CodexBarHistoryWidgetView(entry: entry).content(for: .systemLarge)),
        ]

        for canvas in canvases {
            // WidgetKit supplies context-dependent margins. This host does not, so model a
            // conservative desktop inset explicitly; an installed-widget capture remains required.
            let margins = EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
            let contentSize = CGSize(
                width: canvas.size.width - margins.leading - margins.trailing,
                height: canvas.size.height - margins.top - margins.bottom)

            let rendered = canvas.content
                .frame(width: contentSize.width, height: contentSize.height)
                .padding(margins)
                .frame(width: canvas.size.width, height: canvas.size.height)
            let hosting = NSHostingView(rootView: rendered)
            hosting.appearance = NSAppearance(named: .aqua)
            hosting.frame = NSRect(origin: .zero, size: canvas.size)
            let window = NSWindow(
                contentRect: hosting.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            defer {
                window.contentView = nil
                window.close()
            }

            window.layoutIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let image = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: image)
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("share-overview-\(canvas.name).png"))
        }
    }

    private func canvas(
        _ name: String,
        _ size: CGSize,
        _ view: some View) -> Canvas
    {
        let content = AnyView(
            view
                .background(Color(nsColor: .windowBackgroundColor)))
        return Canvas(name: name, size: size, content: content)
    }
}
