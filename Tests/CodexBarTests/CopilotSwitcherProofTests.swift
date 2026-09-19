import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CopilotSwitcherProofTests {
    @MainActor
    @Test
    func `render production switcher with a configured seat allowance`() throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_COPILOT_SWITCHER_PROOF_DIR"] else { return }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let snapshot = try CopilotSwitcherCreditBarTests().makeSnapshot(used: 1351)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 250))
        container.appearance = NSAppearance(named: .aqua)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.cgColor
        let title = NSTextField(labelWithString: "Copilot · configured seat allowance")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.frame = NSRect(x: 20, y: 210, width: 380, height: 22)
        let detail = NSTextField(labelWithString: "Synthetic usage: 1351 / 3800 AI credits")
        detail.font = .systemFont(ofSize: 12)
        detail.frame = NSRect(x: 20, y: 186, width: 380, height: 20)
        container.addSubview(title)
        container.addSubview(detail)
        var receipt: [[String: Any]] = []
        for (index, showUsed) in [true, false].enumerated() {
            let mode = showUsed ? "Used" : "Remaining"
            let offset = CGFloat(index) * 78
            let label = NSTextField(labelWithString: mode)
            label.font = .systemFont(ofSize: 12)
            label.frame = NSRect(x: 20, y: 146 - offset, width: 380, height: 20)
            container.addSubview(label)
            let switcher = ProviderSwitcherView(
                providers: [.claude, .copilot],
                selected: .provider(.copilot),
                includesOverview: false,
                width: 380,
                showsIcons: false,
                iconProvider: { _ in NSImage(size: NSSize(width: 16, height: 16)) },
                weeklyRemainingProvider: { provider in
                    provider == .copilot
                        ? StatusItemController.switcherWeeklyMetricPercent(
                            for: provider,
                            snapshot: snapshot,
                            showUsed: showUsed)
                        : (showUsed ? 40 : 60)
                },
                onSelect: { _ in })
            switcher.frame.origin = NSPoint(x: 20, y: 110 - offset)
            container.addSubview(switcher)
            switcher.updateConstraintsForSubtreeIfNeeded()
            switcher.layoutSubtreeIfNeeded()
            let percent = StatusItemController.switcherWeeklyMetricPercent(
                for: .copilot,
                snapshot: snapshot,
                showUsed: showUsed)
            receipt.append([
                "mode": mode,
                "copilotPercent": percent.map { $0 as Any } ?? NSNull(),
            ])
        }
        container.updateConstraintsForSubtreeIfNeeded()
        container.layoutSubtreeIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 840,
            pixelsHigh: 500,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0))
        bitmap.size = container.bounds.size
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        container.displayIgnoringOpacity(container.bounds, in: context)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: root.appendingPathComponent("copilot-switcher.png"), options: .atomic)
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("receipt.json"), options: .atomic)
    }
}
