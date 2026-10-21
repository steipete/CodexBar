import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct AutomaticQuotaSelectionTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func `forecast prioritizes imminent depletion over percentage and later depletion`() {
        let highUsage = self.window(90, minutes: 1440, remaining: 3600)
        let weekly = self.window(60, minutes: 10080, remaining: 6 * 86400)
        let session = self.window(60, minutes: 300, remaining: 4 * 3600)
        let selected = AutomaticQuotaSelection.select(
            candidates: [
                .init(window: highUsage, paceSlot: nil),
                .init(window: weekly, paceSlot: .secondary),
                .init(window: session, paceSlot: .primary),
            ],
            provider: .claude,
            now: self.now)
        #expect(selected?.window == session)
        #expect(abs((selected?.eta ?? 0) - 2400) < 0.001)
    }

    @Test
    func `missing or immature forecast falls back to highest percentage with stable ties`() {
        let immature = self.window(50, minutes: 300, remaining: 299 * 60)
        let highUsage = RateWindow(usedPercent: 90, windowMinutes: nil, resetsAt: nil, resetDescription: "first")
        let tied = RateWindow(usedPercent: 90, windowMinutes: nil, resetsAt: nil, resetDescription: "second")
        let selected = AutomaticQuotaSelection.select(
            candidates: [
                .init(window: immature, paceSlot: .primary),
                .init(window: highUsage, paceSlot: nil),
                .init(window: tied, paceSlot: nil),
            ],
            provider: .claude,
            now: self.now)
        #expect(selected?.window == highUsage)
        #expect(selected?.eta == nil)
    }

    @Test
    func `exhausted quota takes priority and invalid readings are excluded`() {
        let exhausted = self.window(100, minutes: 10080, remaining: 86400)
        let session = self.window(60, minutes: 300, remaining: 4 * 3600)
        let invalid = RateWindow(usedPercent: .infinity, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let placeholder = RateWindow(
            usedPercent: 200,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: nil,
            isSyntheticPlaceholder: true)
        #expect(AutomaticQuotaSelection.select(
            candidates: [
                .init(window: invalid, paceSlot: nil),
                .init(window: placeholder, paceSlot: nil),
                .init(window: session, paceSlot: .primary),
                .init(window: exhausted, paceSlot: .secondary),
            ],
            provider: .claude,
            now: self.now)?.window == exhausted)
    }

    @Test
    func `forecast requires the provider to support the candidate lane`() {
        let primaryWindow = self.window(99, minutes: 300, remaining: 1800)
        let secondaryWindow = self.window(95, minutes: 10080, remaining: 86400)
        let snapshot = UsageSnapshot(
            primary: primaryWindow,
            secondary: secondaryWindow,
            updatedAt: self.now)
        let primary = AutomaticQuotaSelection.selection(
            candidate: .init(window: primaryWindow, paceSlot: .primary),
            provider: .opencode,
            now: self.now,
            dataConfidence: snapshot.dataConfidence)
        let secondary = AutomaticQuotaSelection.selection(
            candidate: .init(window: secondaryWindow, paceSlot: .secondary),
            provider: .opencode,
            now: self.now,
            dataConfidence: snapshot.dataConfidence)

        #expect(primary?.eta == nil)
        #expect(secondary?.eta != nil)
        #expect(MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .opencode,
            snapshot: snapshot,
            supportsAverage: false,
            now: self.now) == snapshot.secondary)
    }

    @Test
    func `estimated local usage does not forecast account depletion`() {
        let snapshot = UsageSnapshot(
            primary: window(60, minutes: 300, remaining: 4 * 3600),
            secondary: window(90, minutes: 10080, remaining: 86400),
            updatedAt: now,
            dataConfidence: .estimated)
        #expect(MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .opencodego,
            snapshot: snapshot,
            supportsAverage: false,
            now: self.now) == snapshot.secondary)
        #expect(MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .opencodego,
            snapshot: snapshot.withDataConfidence(.unknown),
            supportsAverage: false,
            now: self.now) == snapshot.primary)
    }

    @Test
    func `descriptors keep optional model quotas and ordered credits separate`() {
        let snapshot = UsageSnapshot(
            primary: window(20, minutes: 300, remaining: 0),
            secondary: window(90, minutes: 10080, remaining: 0),
            tertiary: window(100, minutes: 10080, remaining: 0),
            updatedAt: now)
        for provider in [UsageProvider.claude, .zai, .copilot] {
            #expect(MenuBarMetricWindowResolver.rateWindow(
                preference: .automatic,
                provider: provider,
                snapshot: snapshot,
                supportsAverage: false,
                now: self.now) == snapshot.secondary)
            #expect(MenuBarMetricWindowResolver.rateWindow(
                preference: .primary,
                provider: provider,
                snapshot: snapshot,
                supportsAverage: false,
                now: self.now) == snapshot.primary)
        }
        for provider in [UsageProvider.claudeplatform, .kiro] {
            #expect(MenuBarMetricWindowResolver.rateWindow(
                preference: .automatic,
                provider: provider,
                snapshot: snapshot,
                supportsAverage: false,
                now: self.now) == snapshot.primary)
        }
        let missingChat = UsageSnapshot(
            primary: snapshot.primary,
            secondary: nil,
            tertiary: snapshot.tertiary,
            updatedAt: self.now)
        #expect(MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .copilot,
            snapshot: missingChat,
            supportsAverage: false,
            now: self.now) == missingChat.primary)
        let exhaustedBonus = UsageSnapshot(
            primary: snapshot.primary,
            secondary: snapshot.tertiary,
            updatedAt: self.now)
        #expect(MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .kiro,
            snapshot: exhaustedBonus,
            supportsAverage: false,
            now: self.now) == exhaustedBonus.secondary)
    }

    private func window(_ used: Double, minutes: Int, remaining: TimeInterval) -> RateWindow {
        RateWindow(
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: self.now.addingTimeInterval(remaining),
            resetDescription: nil)
    }
}
