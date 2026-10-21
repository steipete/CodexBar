import Foundation
import Testing
@testable import CodexBarCore
@testable import CodexBarWidget

@MainActor
struct WidgetEmptyStateCopyTests {
    @Test
    func `default widget entry names disabled Codex without changing its pin`() {
        let snapshot = WidgetSnapshot(entries: [], enabledProviders: [.claude, .pi], generatedAt: Date())
        let entry = CodexBarWidgetEntry(
            date: snapshot.generatedAt, provider: ProviderSelectionIntent().provider.provider, snapshot: snapshot)
        WidgetLocalizationOverride.$language.withValue("en") {
            #expect(WidgetEmptyStateCopy.message(provider: entry.provider, snapshot: entry.snapshot) ==
                "Codex is unavailable. Edit the widget to choose a provider.")
        }
        #expect(entry.provider == .codex)
        let metric = CompactMetricSelectionIntent()
        #expect(WidgetEmptyStateCopy.message(provider: metric.provider.provider, snapshot: snapshot) ==
            WidgetEmptyStateCopy.message(provider: entry.provider, snapshot: snapshot))
        #expect(WidgetEmptyStateCopy.message(provider: .claude, snapshot: snapshot) == W("No data"))
    }

    @Test
    func `empty and legacy snapshots point at provider setup`() throws {
        let legacy = try JSONDecoder().decode(
            WidgetSnapshot.self,
            from: Data(#"{"version":1,"generatedAt":0,"entries":[],"usageBarsShowUsed":true}"#.utf8))
        for snapshot in [legacy, WidgetPreviewData.emptySnapshot()] {
            #expect(WidgetEmptyStateCopy.message(provider: .codex, snapshot: snapshot) ==
                W("Enable a provider in CodexBar → Settings → Providers."))
        }
    }

    @Test
    func `switcher recovery points at settings rather than a nonexistent provider editor`() throws {
        let snapshot = WidgetSnapshot(entries: [], enabledProviders: [.grok], generatedAt: Date())
        let resolved = try #require(CodexBarSwitcherTimelineProvider.supportedProviders(from: snapshot).first)
        #expect(WidgetEmptyStateCopy.switcherMessage(provider: resolved, snapshot: snapshot) ==
            W("Enable a provider in CodexBar → Settings → Providers."))
        #expect(WidgetEmptyStateCopy.switcherMessage(provider: .grok, snapshot: snapshot) == W("No data"))
    }
}
