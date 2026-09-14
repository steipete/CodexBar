import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCLI

@MainActor
struct LongCatQuotaPresentationTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func snapshot(hasExpiry: Bool) -> UsageSnapshot {
        LongCatUsageSnapshot(
            totalQuota: 1000,
            usedQuota: 250,
            fuelPackTotal: 500,
            fuelPackRemaining: 200,
            nearestFuelExpiry: hasExpiry ? Self.now.addingTimeInterval(7200) : nil,
            updatedAt: Self.now).toUsageSnapshot()
    }

    private func model(_ snapshot: UsageSnapshot) throws -> UsageMenuCardView.Model {
        let metadata = try #require(ProviderDefaults.metadata[.longcat])
        return UsageMenuCardView.Model.make(.init(
            provider: .longcat,
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

    @Test(arguments: [false, true])
    func `quota counts remain details alongside actual fuel expiry`(hasExpiry: Bool) throws {
        let snapshot = self.snapshot(hasExpiry: hasExpiry)
        let model = try self.model(snapshot)
        let primary = try #require(model.metrics.first { $0.id == "primary" })
        let fuel = try #require(model.metrics.first { $0.id == "secondary" })
        #expect(primary.percent == 75)
        #expect(primary.detailText == "250/1000")
        #expect(primary.resetText == nil)
        #expect(fuel.percent == 40)
        #expect(fuel.detailText == "Fuel pack: 200/500")
        #expect(fuel.resetText == (hasExpiry ? "Resets in 2h" : nil))

        let settings = testSettingsStore(
            suiteName: "LongCatQuotaPresentationTests-\(hasExpiry)",
            userDefaults: InMemoryUserDefaults())
        settings.statusChecksEnabled = false
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        store._setSnapshotForTesting(snapshot, provider: .longcat)
        let descriptor = MenuDescriptor.build(
            provider: .longcat,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)
        let text = descriptor.sections.flatMap(\.entries).compactMap { entry -> String? in
            guard case let .text(value, _) = entry else { return nil }
            return value
        }
        #expect(text.contains("250/1000"))
        #expect(text.contains("Fuel pack: 200/500"))
        #expect(!text.contains { $0.hasPrefix("Resets 250/") || $0.hasPrefix("Resets Fuel pack:") })
        #expect(text.contains { $0.hasPrefix("Resets ") } == hasExpiry)
    }

    @Test(arguments: [false, true])
    func `CLI text and cards keep balances separate from expiry`(hasExpiry: Bool) throws {
        let snapshot = self.snapshot(hasExpiry: hasExpiry)
        let metadata = ProviderDescriptorRegistry.descriptor(for: .longcat).metadata
        let card = CLICardsRenderer.makeCard(CLICardBuildInput(
            provider: .longcat,
            snapshot: snapshot,
            credits: nil,
            source: "web",
            status: nil,
            notes: [],
            useColor: false,
            resetStyle: .countdown,
            weeklyWorkDays: nil,
            now: Self.now))
        let primary = try #require(card.metrics.first { $0.label == metadata.sessionLabel })
        let fuel = try #require(card.metrics.first { $0.label == metadata.weeklyLabel })
        #expect(primary.detailText == "250/1000")
        #expect(primary.resetText == nil)
        #expect(fuel.detailText == "Fuel pack: 200/500")
        #expect(fuel.resetText == (hasExpiry ? "⏳ Resets in 2h" : nil))

        let output = CLIRenderer.renderText(
            provider: .longcat,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(header: "LongCat", status: nil, useColor: false, resetStyle: .countdown),
            now: Self.now)
        #expect(output.contains("250/1000"))
        #expect(output.contains("Fuel pack: 200/500"))
        #expect(!output.contains("Resets 250/") && !output.contains("Resets Fuel pack:"))
        #expect(output.contains("Resets in 2h") == hasExpiry)
    }

    @Test
    func `render synthetic quota cards`() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_LONGCAT_SCREENSHOT_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for hasExpiry in [false, true] {
            let model = try self.model(self.snapshot(hasExpiry: hasExpiry))
            for dark in [false, true] {
                let view = UsageMenuCardView(model: model, width: 340)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .background(Color(nsColor: NSColor(calibratedWhite: dark ? 0.12 : 1, alpha: 1)))
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let png = try #require(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                let name = "longcat-\(hasExpiry ? "expiry" : "balance")-\(dark ? "dark" : "light").png"
                try png.write(to: directory.appendingPathComponent(name))
            }
        }
    }
}
