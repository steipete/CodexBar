import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct QuotaBurndownRenderProofTests {
    enum Fixture: String, CaseIterable {
        case session, weekly, monthly, claude, before, after
    }

    @Test(arguments: Fixture.allCases, [false, true])
    func `render synthetic quota charts in both appearances`(fixture: Fixture, dark: Bool) throws {
        let now = Date(timeIntervalSince1970: 1_790_553_600)
        let weekly = fixture != .session
        let minutes = fixture == .monthly ? 43200 : weekly ? 10080 : 300
        let reset = now.addingTimeInterval(weekly ? 2 * 86400 : 2 * 3600)
        let interval: TimeInterval = weekly ? 86400 : 3600
        let history = PlanUtilizationSeriesHistory(
            name: fixture == .monthly ? .monthly : weekly ? .weekly : .session,
            windowMinutes: minutes,
            entries: [
                .init(capturedAt: now.addingTimeInterval(-2 * interval), usedPercent: 10, resetsAt: reset),
                .init(capturedAt: now.addingTimeInterval(-interval), usedPercent: 35, resetsAt: reset),
                .init(capturedAt: now.addingTimeInterval(-interval / 2), usedPercent: 60, resetsAt: reset),
            ])
        let histories = fixture == .claude ? [history, PlanUtilizationSeriesHistory(
            name: .opus,
            windowMinutes: 10080,
            entries: [.init(capturedAt: now.addingTimeInterval(-7200), usedPercent: 30, resetsAt: reset)])] : [history]
        let provider: UsageProvider = fixture == .claude ? .claude : .codex
        let view = VStack(spacing: 0) {
            if fixture != .before {
                QuotaBurndownChartMenuView(provider: provider, histories: histories, width: 400, referenceDate: now)
            }
            if fixture == .after { Divider() }
            if fixture == .before || fixture == .after {
                PlanUtilizationHistoryChartMenuView(
                    provider: provider, histories: histories, width: 400, referenceDate: now)
            }
        }
        .frame(width: 400)
        .padding(12)
        .background(dark ? Color.black : Color.white)
        .environment(\.colorScheme, dark ? .dark : .light)
        let hosting = NSHostingView(rootView: view)
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        hosting.appearance = appearance
        var bitmap: NSBitmapImageRep?
        appearance.performAsCurrentDrawingAppearance {
            hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
            hosting.layoutSubtreeIfNeeded()
            #expect(hosting.bounds.width == 424)
            #expect(hosting.bounds.height > 150)
            bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
            if let bitmap { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
        }
        let png = try #require(bitmap?.representation(using: .png, properties: [:]))
        if let path = ProcessInfo.processInfo.environment["CODEXBAR_BURNDOWN_PROOF_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent("\(fixture.rawValue)-\(dark ? "dark" : "light").png"))
        }
    }
}
