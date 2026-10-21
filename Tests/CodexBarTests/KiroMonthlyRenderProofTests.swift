import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct KiroMonthlyRenderProofTests {
    @Test(arguments: [false, true])
    func `render synthetic Kiro card and recorded monthly history`(dark: Bool) async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_KIRO_PROOF_DIR"] else { return }
        let now = KiroPlanUtilizationHistoryTests.now
        let store = KiroPlanUtilizationHistoryTests.makeStore()
        store.settings.historicalTrackingEnabled = true
        let snapshot = KiroPlanUtilizationHistoryTests.snapshot()
        for (days, used) in [(10.0, 10.0), (7, 25), (3, 40), (0, 60)] {
            await store.recordPlanUtilizationHistorySample(
                provider: .kiro,
                snapshot: KiroPlanUtilizationHistoryTests.snapshot(used: used),
                now: now.addingTimeInterval(-days * 86400))
        }
        let model = try UsageMenuCardView.Model.make(.init(
            provider: .kiro,
            metadata: #require(ProviderDefaults.metadata[.kiro]),
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            now: now))
        let histories = store.planUtilizationHistory(for: .kiro)
        let view = VStack(spacing: 12) {
            UsageMenuCardView(model: model, width: 400)
            if !histories.isEmpty {
                Text("Plan Usage").font(.headline)
                QuotaBurndownChartMenuView(provider: .kiro, histories: histories, width: 400, referenceDate: now)
                PlanUtilizationHistoryChartMenuView(
                    provider: .kiro, histories: histories, width: 400, referenceDate: now)
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, dark ? .dark : .light)
        let hosting = NSHostingView(rootView: view)
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        hosting.appearance = appearance
        var bitmap: NSBitmapImageRep?
        appearance.performAsCurrentDrawingAppearance {
            hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
            hosting.layoutSubtreeIfNeeded()
            #expect(hosting.bounds.width >= 400)
            #expect(hosting.bounds.height > 150)
            bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
            if let bitmap { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
        }
        let png = try #require(bitmap?.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("kiro-\(dark ? "dark" : "light").png"))
    }
}
