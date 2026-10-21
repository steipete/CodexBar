import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuBarMetricFallbackTests {
    @Test(arguments: [40.0, 100.0], [true, false])
    func `shared metrics fall back to a lone tertiary quota`(usedPercent: Double, supportsAverage: Bool) {
        let tertiary = RateWindow(
            usedPercent: usedPercent,
            windowMinutes: 1440,
            resetsAt: Date(timeIntervalSince1970: 2_000_000_000),
            resetDescription: "Daily")
        let snapshot = UsageSnapshot(primary: nil, secondary: nil, tertiary: tertiary, updatedAt: .distantPast)
        for preference in [MenuBarMetricPreference.automatic, .primary, .secondary, .tertiary, .average] {
            let window = MenuBarMetricWindowResolver.rateWindow(
                preference: preference,
                provider: .opencode,
                snapshot: snapshot,
                supportsAverage: supportsAverage)
            #expect(window == tertiary, "Failed preference: \(preference)")
        }
    }

    @Test
    func `shared fallback does not invent missing quota or spend metrics`() {
        let empty = UsageSnapshot(primary: nil, secondary: nil, updatedAt: .distantPast)
        for preference in [MenuBarMetricPreference.automatic, .primary, .secondary, .tertiary, .average] {
            #expect(MenuBarMetricWindowResolver.rateWindow(
                preference: preference, provider: .opencode, snapshot: empty, supportsAverage: true) == nil)
        }
        let tertiary = RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let snapshot = UsageSnapshot(primary: nil, secondary: nil, tertiary: tertiary, updatedAt: .distantPast)
        for preference in [MenuBarMetricPreference.primaryAndSecondary, .extraUsage, .monthlyPlan] {
            #expect(MenuBarMetricWindowResolver.rateWindow(
                preference: preference, provider: .opencode, snapshot: snapshot, supportsAverage: true) == nil)
        }
    }

    @Test
    func `shared fallback preserves preferred lanes and two-window average`() {
        let primary = RateWindow(usedPercent: 30, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let secondary = RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let tertiary = RateWindow(usedPercent: 70, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let snapshot = UsageSnapshot(
            primary: primary, secondary: secondary, tertiary: tertiary, updatedAt: .distantPast)
        let expectations: [(MenuBarMetricPreference, Double)] = [
            (.automatic, 70), (.primary, 30), (.secondary, 50), (.tertiary, 30), (.average, 40),
        ]
        for (preference, expected) in expectations {
            #expect(MenuBarMetricWindowResolver.rateWindow(
                preference: preference,
                provider: .opencode,
                snapshot: snapshot,
                supportsAverage: true)?.usedPercent == expected)
        }
        #expect(MenuBarMetricWindowResolver.rateWindow(
            preference: .average, provider: .opencode, snapshot: snapshot, supportsAverage: false) == primary)
    }
}
