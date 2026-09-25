import AppKit
import CodexBarCore
import SwiftUI
import WidgetKit
import XCTest
@testable import CodexBarWidget

@MainActor
final class BurnDownRenderProofTests: XCTestCase {
    func test_syntheticBurnDowns() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_BURN_DOWN_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_BURN_DOWN_PROOF_DIR for synthetic offscreen rendering")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (provider, minutes) in [(UsageProvider.devin, 1440), (.cursor, 43200), (.codex, 300)] {
            let now = Date()
            let primary = RateWindow(
                usedPercent: 25,
                windowMinutes: minutes,
                resetsAt: now.addingTimeInterval(Double(minutes) * 30),
                resetDescription: nil)
            let secondary = RateWindow(
                usedPercent: 45,
                windowMinutes: provider == .cursor ? minutes : 10080,
                resetsAt: now.addingTimeInterval(86400),
                resetDescription: nil)
            let snapshot = BurnDownCapabilityTests.snapshot(provider: provider, primary: primary, secondary: secondary)
            let view = CombinedBurnDownWidgetView(entry: .init(date: now, provider: provider, snapshot: snapshot))
                .environment(\.colorScheme, .light)
                .environment(\.widgetRenderingMode, .fullColor)
                .frame(width: 360, height: 170)
                .background(Color(white: 0.97))
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 170)
            hosting.appearance = NSAppearance(named: .aqua)
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent("\(provider.rawValue).png"))
        }
    }
}
