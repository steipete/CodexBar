import CodexBarCore
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI

@MainActor
struct OpenCodeGoEstimatedPaceTests {
    @Test(arguments: [UsageDataConfidence.estimated, .unknown, .exact])
    func `CLI quota and disclosure survive while only authoritative windows get pace`(
        confidence: UsageDataConfidence)
    {
        let snapshot = OpenCodeGoPaceTestSupport.snapshot(confidence: confidence)
        let expectedPace = confidence != .estimated
        let context = RenderContext(
            header: "OpenCode Go",
            status: nil,
            useColor: false,
            resetStyle: .countdown,
            notes: CodexBarCLI.usageTextNotes(
                provider: .opencodego,
                sourceMode: .auto,
                resolvedSourceLabel: expectedPace ? "local+api" : "local",
                dataConfidence: confidence))
        let text = CLIRenderer.renderText(
            provider: .opencodego,
            snapshot: snapshot,
            credits: nil,
            context: context,
            now: OpenCodeGoPaceTestSupport.now)
        let pace = CLIRenderer.providerPacePayload(
            provider: .opencodego, snapshot: snapshot, now: OpenCodeGoPaceTestSupport.now)

        #expect(text.contains("Monthly: 95% left"))
        #expect(text.contains("Weekly: 96% left"))
        #expect(text.contains("Resets in"))
        #expect(text.contains("Quota estimated from local usage history") == !expectedPace)
        #expect(text.contains("Pace:") == expectedPace)
        #expect(text.contains("Lasts until reset") == expectedPace)
        #expect((pace != nil) == expectedPace)
        if expectedPace {
            #expect(pace?.primary != nil)
            #expect(pace?.secondary != nil)
            #expect(pace?.tertiary != nil)
        }
    }

    @Test
    func `encoded local usage omits pace but keeps confidence and reset windows`() throws {
        let snapshot = OpenCodeGoPaceTestSupport.snapshot(confidence: .estimated, now: Date())
        let payload = ProviderPayload(
            provider: .opencodego,
            account: nil,
            version: nil,
            source: "local",
            status: nil,
            usage: snapshot,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: nil,
            pace: CLIRenderer.providerPacePayload(provider: .opencodego, snapshot: snapshot))
        let data = try JSONEncoder().encode(payload)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let usage = try #require(json["usage"] as? [String: Any])

        #expect(json["pace"] == nil)
        #expect(usage["dataConfidence"] as? String == "estimated")
        #expect((usage["tertiary"] as? [String: Any])?["usedPercent"] as? Double == 5)
        #expect((usage["tertiary"] as? [String: Any])?["resetsAt"] != nil)
    }

    @Test(arguments: [UsageDataConfidence.estimated, .unknown, .exact])
    func `menu card preserves quotas but does not forecast from local estimates`(
        confidence: UsageDataConfidence) throws
    {
        let model = UsageMenuCardView.Model.make(OpenCodeGoPaceTestSupport.input(confidence: confidence))
        let monthly = try #require(model.metrics.first { $0.id == "tertiary" })
        let expectedPace = confidence != .estimated

        #expect(model.metrics.map(\.title) == ["5-hour", "Weekly", "Monthly"])
        #expect(monthly.percentLabel == "95% left")
        #expect(monthly.resetText != nil)
        #expect(model.usageNotes == (expectedPace ? [] : [L("Quota estimated from local usage history")]))
        #expect((monthly.detailRightText != nil) == expectedPace)
        #expect((monthly.pacePercent != nil) == expectedPace)
        if !expectedPace {
            #expect(model.metrics.allSatisfy { $0.pacePercent == nil })
            #expect(model.metrics.allSatisfy { $0.detailLeftText == nil && $0.detailRightText == nil })
        }
    }

    @Test(arguments: [UsageDataConfidence.estimated, .unknown, .exact])
    func `menu bar pace uses the displayed snapshot confidence instead of the selected account`(
        confidence: UsageDataConfidence) throws
    {
        let settings = testSettingsStore(
            suiteName: "OpenCodeGoEstimatedPaceTests-layout-\(confidence)",
            config: testConfigWithAllProvidersDisabled())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let expectedPace = confidence != .estimated
        store._setSnapshotForTesting(
            OpenCodeGoPaceTestSupport.snapshot(confidence: expectedPace ? .estimated : .exact), provider: .opencodego)
        let window = try #require(OpenCodeGoPaceTestSupport.snapshot(confidence: confidence).secondary)
        let pace = store.weeklyPace(
            provider: .opencodego, window: window, dataConfidence: confidence, now: OpenCodeGoPaceTestSupport.now)
        let text = store.menuBarLayoutPaceText(
            provider: .opencodego, window: window, dataConfidence: confidence, now: OpenCodeGoPaceTestSupport.now)
        let delta = store.menuBarLayoutPaceDelta(
            provider: .opencodego, window: window, dataConfidence: confidence, now: OpenCodeGoPaceTestSupport.now)

        #expect((pace != nil) == expectedPace)
        #expect((text != nil) == expectedPace)
        #expect((delta != nil) == expectedPace)
        if !expectedPace {
            for mode in [MenuBarDisplayMode.pace, .both] {
                #expect(MenuBarDisplayText.displayText(
                    mode: mode, percentWindow: window, pace: pace, showUsed: false) == "96%")
            }
        }
        #expect(store.weeklyPace(
            provider: .zai, window: window, dataConfidence: .estimated, now: OpenCodeGoPaceTestSupport.now) != nil)
    }

    @Test
    func `only OpenCode Go opts out of estimated pace`() {
        for provider in UsageProvider.allCases {
            let capability = ProviderDescriptorRegistry.descriptor(for: provider).pace
            #expect(capability.allowsPace(dataConfidence: .estimated) == (provider != .opencodego))
            #expect(capability.allowsPace(dataConfidence: .unknown))
            #expect(capability.allowsPace(dataConfidence: .exact))
        }
    }

    @Test(arguments: [UsageDataConfidence.estimated, .unknown, .exact])
    func `legacy menu omits estimate forecasts without hiding quota rows`(confidence: UsageDataConfidence) {
        let settings = testSettingsStore(
            suiteName: "OpenCodeGoEstimatedPaceTests-legacy-\(confidence)",
            config: testConfigWithAllProvidersDisabled())
        settings.paceVisible = true
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._setSnapshotForTesting(
            OpenCodeGoPaceTestSupport.snapshot(confidence: confidence, now: Date()), provider: .opencodego)
        let menu = MenuDescriptor.build(
            provider: .opencodego,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false)
        let texts = menu.sections.flatMap(\.entries).compactMap { entry -> String? in
            guard case let .text(text, _) = entry else { return nil }
            return text
        }

        #expect(texts.contains { $0.contains("Monthly") })
        #expect(texts.contains { $0.contains("Pace:") } == (confidence != .estimated))
    }
}

enum OpenCodeGoPaceTestSupport {
    static let now = Date(timeIntervalSince1970: 10_368_000)

    static func snapshot(confidence: UsageDataConfidence, now: Date = Self.now) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0, windowMinutes: 300, resetsAt: now.addingTimeInterval(3 * 3600), resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 4,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(8 * 3600),
                resetDescription: nil),
            tertiary: RateWindow(
                usedPercent: 5,
                windowMinutes: 43200,
                resetsAt: now.addingTimeInterval(6 * 86400),
                resetDescription: nil),
            updatedAt: now,
            dataConfidence: confidence)
    }

    static func input(confidence: UsageDataConfidence) -> UsageMenuCardView.Model.Input {
        .init(
            provider: .opencodego,
            metadata: ProviderDefaults.metadata[.opencodego]!,
            snapshot: self.snapshot(confidence: confidence),
            credits: nil,
            creditsError: nil,
            dashboard: nil,
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
            now: self.now)
    }
}
