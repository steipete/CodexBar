import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

@MainActor
struct ProviderQuotaDetailPresentationTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func snapshot(provider: UsageProvider, hasReset: Bool) async throws -> UsageSnapshot {
        let reset = hasReset ? Self.now.addingTimeInterval(7200) : nil
        switch provider {
        case .mistral:
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 20,
                    windowMinutes: nil,
                    resetsAt: reset,
                    resetDescription: "€10.00 / €50.00 · €40.00 left"),
                secondary: nil,
                updatedAt: Self.now)
        case .manus:
            return ManusCreditsResponse(
                totalCredits: 2869,
                freeCredits: 1500,
                periodicCredits: 1369,
                addonCredits: 0,
                refreshCredits: 0,
                maxRefreshCredits: 300,
                proMonthlyCredits: 4000,
                eventCredits: 0,
                nextRefreshTime: reset,
                refreshInterval: "daily").toUsageSnapshot(now: Self.now)
        case .mimo:
            return MiMoUsageSnapshot(
                balance: 25.51,
                currency: "USD",
                planCode: "standard",
                planPeriodEnd: reset,
                tokenUsed: 10_100_158,
                tokenLimit: 200_000_000,
                tokenPercent: 0.0505,
                updatedAt: Self.now).toUsageSnapshot()
        case .neuralwatt:
            let body: [String: Any] = ["balance": ["credits_remaining_usd": 32.6774], "subscription": [
                "plan": "standard", "status": "active", "kwh_included": 20,
                "kwh_used": 13.9023, "kwh_remaining": 6.0977,
                "current_period_end": reset.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
            ]]
            let data = try JSONSerialization.data(withJSONObject: body)
            return try await NeuralWattPluginTestSupport.fetch(data, now: Self.now)
        default:
            preconditionFailure("Unexpected provider fixture")
        }
    }

    private func expectedDetails(_ provider: UsageProvider) -> [String] {
        switch provider {
        case .mistral: ["€10.00 / €50.00 · €40.00 left"]
        case .manus: ["Total 2,869 • Free 1,500", "Daily: 0 / 300"]
        case .mimo: ["10,100,158 / 200,000,000 Credits"]
        case .neuralwatt: ["13.90 / 20 kWh"]
        default: []
        }
    }

    private func model(provider: UsageProvider, snapshot: UsageSnapshot) throws -> UsageMenuCardView.Model {
        let metadata = try #require(ProviderDefaults.metadata[provider])
        return UsageMenuCardView.Model.make(.init(
            provider: provider,
            metadata: metadata,
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
            hidePersonalInfo: false,
            now: Self.now))
    }

    @Test(arguments: [UsageProvider.manus, .mimo, .neuralwatt, .mistral], [false, true])
    func `CLI keeps quota details visible without inventing reset clocks`(
        provider: UsageProvider, hasReset: Bool) async throws
    {
        let snapshot = try await self.snapshot(provider: provider, hasReset: hasReset)
        let details = self.expectedDetails(provider)
        let windows = [snapshot.primary, snapshot.secondary].compactMap(\.self)
        #expect(windows.compactMap(\.resetDescription) == details)
        let card = CLICardsRenderer.makeCard(CLICardBuildInput(
            provider: provider,
            snapshot: snapshot,
            credits: nil,
            source: "synthetic",
            status: nil,
            notes: [],
            useColor: false,
            resetStyle: .countdown,
            weeklyWorkDays: nil,
            now: Self.now))
        #expect(card.metrics.count == details.count)
        for (metric, window) in zip(card.metrics, windows) {
            #expect(metric.detailText == window.resetDescription)
            #expect(metric.resetText == (window.resetsAt == nil ? nil : "⏳ Resets in 2h"))
            #expect(metric.remainingPercent == window.remainingPercent)
        }
        let text = CLIRenderer.renderText(
            provider: provider,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(header: "Synthetic quota", status: nil, useColor: false, resetStyle: .countdown),
            now: Self.now)
        for detail in details {
            #expect(text.contains(detail))
            #expect(!text.contains("Resets \(detail)"))
        }
        #expect(text.contains("Resets in 2h") == hasReset)
        if let path = ProcessInfo.processInfo.environment["CODEXBAR_QUOTA_DETAIL_PROOF_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "\(provider.rawValue)-\(hasReset ? "reset" : "balance")"
            let cards = CLICardsRenderer.render(cards: [card], failures: [], terminalWidth: 100, useColor: false)
            try text.write(to: directory.appendingPathComponent("\(name)-text.txt"), atomically: true, encoding: .utf8)
            try cards.write(
                to: directory.appendingPathComponent("\(name)-cards.txt"),
                atomically: true,
                encoding: .utf8)
        }
    }

    @Test(arguments: [UsageProvider.manus, .mimo, .neuralwatt, .mistral], [false, true])
    func `native menus and cards retain quota details alongside real resets`(
        provider: UsageProvider, hasReset: Bool) async throws
    {
        let snapshot = try await self.snapshot(provider: provider, hasReset: hasReset)
        let settings = testSettingsStore(
            suiteName: "ProviderQuotaDetailPresentationTests-\(provider.rawValue)-\(hasReset)",
            userDefaults: InMemoryUserDefaults())
        settings.statusChecksEnabled = false
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        store._setSnapshotForTesting(snapshot, provider: provider)
        let menu = MenuDescriptor.build(
            provider: provider,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)
        let text = menu.sections.flatMap(\.entries).compactMap { entry -> String? in
            guard case let .text(value, _) = entry else { return nil }
            return value
        }
        for detail in self.expectedDetails(provider) {
            #expect(text.contains(detail))
            #expect(!text.contains("Resets \(detail)"))
        }
        #expect(text.contains { $0.hasPrefix("Resets ") } == hasReset)
        let model = try self.model(provider: provider, snapshot: snapshot)
        let windows = [snapshot.primary, snapshot.secondary].compactMap(\.self)
        #expect(model.metrics.count == windows.count)
        for (metric, window) in zip(model.metrics, windows) {
            #expect(metric.detailText == window.resetDescription)
            #expect(metric.resetText == (window.resetsAt == nil ? nil : "Resets in 2h"))
            #expect(abs(metric.percent - window.remainingPercent) < 0.000001)
        }
    }

    @Test
    func `render synthetic Manus card proof`() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_QUOTA_DETAIL_PROOF_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for hasReset in [false, true] {
            let snapshot = try await self.snapshot(provider: .manus, hasReset: hasReset)
            let model = try self.model(provider: .manus, snapshot: snapshot)
            for dark in [false, true] {
                let view = UsageMenuCardView(model: model, width: 340)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .background(Color(nsColor: NSColor(calibratedWhite: dark ? 0.12 : 1, alpha: 1)))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let png = try #require(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                let name = "manus-\(hasReset ? "reset" : "balance")-\(dark ? "dark" : "light").png"
                try png.write(to: directory.appendingPathComponent(name))
            }
        }
    }
}
