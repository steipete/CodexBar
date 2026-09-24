import AppKit
import CodexBarCore
import SwiftUI
import WidgetKit
import XCTest
@testable import CodexBarWidget

/// Opt-in synthetic rendering of production views; not desktop WidgetKit compositor proof.
@MainActor
final class WidgetAccountVisualProofTests: XCTestCase {
    func test_render() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_ACCOUNT_RENDER_DIR"] else {
            throw XCTSkip("Opt-in visual audit")
        }
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let now = Date()
        func usage(_ used: Double, activity: Bool = false, extra: Bool = false) -> WidgetSnapshot.ProviderEntry {
            WidgetSnapshot.ProviderEntry(
                provider: .claude,
                updatedAt: now,
                primary: RateWindow(
                    usedPercent: used,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 45,
                    windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(86400 * 3),
                    resetDescription: nil),
                tertiary: extra ? RateWindow(
                    usedPercent: 20,
                    windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(86400 * 3),
                    resetDescription: nil) : nil,
                creditsRemaining: nil,
                codeReviewRemainingPercent: nil,
                tokenUsage: activity ? .init(
                    sessionCostUSD: 1.5,
                    sessionTokens: 1200,
                    last30DaysCostUSD: 30,
                    last30DaysTokens: 24000,
                    sessionLabel: "Today",
                    updatedAt: now) : nil,
                dailyUsage: activity ? (1...22).map {
                    .init(
                        dayKey: String(format: "2026-09-%02d", $0),
                        totalTokens: $0 * 100,
                        costUSD: Double(($0 * 7) % 11) / 10)
                } : [])
        }
        for extra in [false, true] {
            let accounts: [WidgetSnapshot.AccountEntry] = (1...6).map {
                .init(
                    id: "account-\($0)",
                    provider: .claude,
                    label: "Account \($0)",
                    usage: usage($0 == 6 ? 80 : 25, extra: extra),
                    isActive: $0 == 6)
            }
            let snapshot = WidgetSnapshot(
                entries: [usage(80, activity: true, extra: extra)],
                accounts: accounts,
                enabledProviders: [.claude],
                generatedAt: now)
            let entry = CodexBarWidgetEntry(date: now, provider: .claude, snapshot: snapshot)
            let pin = CodexBarAccountTimelineProvider.makeEntry(
                snapshot: snapshot,
                provider: .claude,
                accountID: "account-6",
                now: now)
            for dark in [false, true] {
                for family in [WidgetFamily.systemSmall, .systemMedium, .systemLarge] {
                    let size = CGSize(
                        width: family == .systemSmall ? 155 : 329,
                        height: family == .systemLarge ? 345 : 155)
                    let tag = "\(extra ? "three" : "two")-\(dark ? "dark" : "light")-\(family.rawValue)"
                    func render(_ view: some View, _ name: String) throws {
                        let framed = view
                            .environment(\.widgetFamilyOverride, family)
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .environment(\.widgetRenderingModeOverride, .fullColor)
                            .frame(width: size.width - 32, height: size.height - 32)
                            .padding(16)
                            .background(dark ? Color(white: 0.12) : .white)
                        let renderer = ImageRenderer(content: framed)
                        renderer.scale = 2
                        let cgImage = try XCTUnwrap(renderer.cgImage)
                        let bitmap = NSBitmapImageRep(cgImage: cgImage)
                        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        try data.write(to: output.appendingPathComponent("\(name)-\(tag).png"))
                    }
                    try render(CodexBarUsageWidgetView(entry: entry), "usage")
                    try render(CodexBarAccountUsageWidgetView(entry: pin), "pinned")
                    try render(CodexBarSwitcherWidgetView(entry: .init(
                        date: now,
                        provider: .claude,
                        availableProviders: [.codex, .claude],
                        snapshot: snapshot)), "switcher")
                    if family != .systemSmall {
                        try render(CodexBarAccountsWidgetView(entry: entry), "accounts")
                        try render(CodexBarHistoryWidgetView(entry: entry), "history")
                    }
                    if family == .systemSmall {
                        try render(
                            CodexBarCompactWidgetView(entry: .init(
                                date: now,
                                provider: .claude,
                                metric: .todayCost,
                                snapshot: snapshot)),
                            "metric")
                    }
                    if family == .systemMedium {
                        try render(BurnDownWidgetView(entry: .init(
                            date: now,
                            provider: .claude,
                            window: .session,
                            snapshot: snapshot)), "burn")
                        try render(CombinedBurnDownWidgetView(entry: .init(
                            date: now,
                            provider: .claude,
                            snapshot: snapshot)), "combined-burn")
                    }
                }
            }
        }
    }
}
