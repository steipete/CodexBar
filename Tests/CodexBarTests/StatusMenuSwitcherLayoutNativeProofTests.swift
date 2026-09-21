import AppKit
import XCTest
@testable import CodexBar

@MainActor
final class StatusMenuSwitcherLayoutNativeProofTests: XCTestCase {
    func test_captureSyntheticStackedSwitcher() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_SWITCHER_LAYOUT_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_SWITCHER_LAYOUT_PROOF_DIR for synthetic layout proof")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let view = ProviderSwitcherView(
            providers: [
                .codex, .claude, .cursor, .antigravity, .copilot, .warp, .perplexity,
                .deepseek, .commandcode, .grok, .notion, .gemini, .devin,
            ],
            selected: .overview,
            includesOverview: true,
            width: 310,
            showsIcons: true,
            iconProvider: { _ in NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil) ?? NSImage() },
            weeklyRemainingProvider: { _ in 50 },
            onSelect: { _ in })
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: view.intrinsicContentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view._test_rowCount(), 3)
        let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent("provider-switcher.png"), options: .atomic)
        let receipt: [String: Any] = [
            "syntheticOnly": true,
            "titles": view._test_segmentTitles(),
            "rows": view._test_rowCount(),
            "buttons": view._test_buttonFrames().map(NSStringFromRect),
            "contents": view._test_buttonContentFrames().map { $0.map(NSStringFromRect) ?? "none" },
        ]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("geometry.json"), options: .atomic)
    }
}
