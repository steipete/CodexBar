import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct AntigravityBarSelectionTests {
    private let geminiID = "antigravity-quota-summary-gemini-weekly"
    private let fableID = "antigravity-quota-summary-fictional-fable-weekly"

    @Test
    func `saved Cursor extra uses the unified weekly projection`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 80, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            cursorHasUnifiedWeeklyPool: true,
            updatedAt: Date())
        #expect(snapshot.extraRateWindows == nil)
        #expect(StatusItemController.switcherWeeklyMetricPercent(
            for: .cursor,
            snapshot: snapshot,
            showUsed: false,
            percentWindowPreference: .extra(id: "cursor-grok-bot")) == 20)
    }

    private func snapshot(selected: NamedRateWindow?) -> UsageSnapshot {
        UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [NamedRateWindow(
                id: "antigravity-quota-summary-3p-weekly",
                title: "Claude/GPT weekly",
                window: RateWindow(usedPercent: 84, windowMinutes: 10080, resetsAt: nil, resetDescription: nil))]
                + (selected.map { [$0] } ?? []),
            updatedAt: Date())
    }

    @Test
    func `dynamic family can be selected and drives the switcher`() {
        let selected = NamedRateWindow(
            id: self.fableID,
            title: "Fictional Fable weekly",
            window: RateWindow(usedPercent: 12, windowMinutes: 10080, resetsAt: nil, resetDescription: nil))
        let snapshot = self.snapshot(selected: selected)
        let layout = MenuBarLayout(lines: [[.icon, .extraPercent(id: self.geminiID)]])
        let picker = ProviderMenuBarPercentWindowPicker(
            provider: .antigravity, iconStyle: .iconAndPercent, layout: .constant(layout), snapshot: snapshot)
        let option = MenuBarPercentWindowPreference.extra(id: self.fableID)
        #expect(picker.available.contains(option))
        #expect(option.label(for: .antigravity, snapshot: snapshot) == selected.title)
        #expect(MenuBarPercentWindowPreference.current(in: option.applied(to: layout)) == option)
        #expect(StatusItemController.switcherWeeklyMetricPercent(
            for: .antigravity, snapshot: snapshot, showUsed: false, percentWindowPreference: option) == 88)
    }

    @Test
    func `unavailable selected family never falls back to a different family`() {
        let ordinary = RateWindow(usedPercent: 12, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)
        let missing: NamedRateWindow? = nil
        let candidates = [
            missing,
            NamedRateWindow(id: self.fableID, title: "Fable", window: ordinary, usageKnown: false),
            NamedRateWindow(
                id: self.fableID,
                title: "Fable",
                window: RateWindow(usedPercent: .nan, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
            NamedRateWindow(
                id: self.fableID,
                title: "Fable",
                window: RateWindow(
                    usedPercent: 0,
                    windowMinutes: 10080,
                    resetsAt: nil,
                    resetDescription: nil,
                    isSyntheticPlaceholder: true)),
        ]
        for selected in candidates {
            #expect(StatusItemController.switcherWeeklyMetricPercent(
                for: .antigravity,
                snapshot: self.snapshot(selected: selected),
                showUsed: false,
                percentWindowPreference: .extra(id: self.fableID)) == nil)
        }
    }

    @Test
    func `independent multi window layouts do not offer no op family choices`() {
        let selected = NamedRateWindow(
            id: self.fableID,
            title: "Fictional Fable weekly",
            window: RateWindow(usedPercent: 12, windowMinutes: 10080, resetsAt: nil, resetDescription: nil))
        for layout in [
            MenuBarLayout(lines: [[.extraPercent(id: self.geminiID), .extraPercent(id: "other")]]),
            MenuBarLayout(lines: [[.percent(window: .weekly), .extraPercent(id: self.geminiID)]]),
        ] {
            let picker = ProviderMenuBarPercentWindowPicker(
                provider: .antigravity,
                iconStyle: .iconAndPercent,
                layout: .constant(layout),
                snapshot: self.snapshot(selected: selected))
            #expect(!picker.available.contains(.extra(id: self.fableID)))
        }
    }
}
