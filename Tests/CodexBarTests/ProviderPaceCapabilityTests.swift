import CodexBarCore
import Foundation
import Testing

struct ProviderPaceCapabilityTests {
    private static let weeklyWindowMinutes = 7 * 24 * 60
    private static let monthlyWindowSentinelMinutes = 30 * 24 * 60

    @Test
    func `descriptor pace capabilities preserve the legacy provider mapping`() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let fixtures: [RateWindow] = [
            Self.window(minutes: nil, resetsAt: nil),
            Self.window(minutes: nil, resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60)),
            Self.window(minutes: nil, resetsAt: now.addingTimeInterval(8 * 24 * 60 * 60)),
            Self.window(minutes: nil, resetsAt: now.addingTimeInterval(30 * 24 * 60 * 60)),
            Self.window(minutes: 60, resetsAt: now.addingTimeInterval(30 * 60)),
            Self.window(minutes: Self.weeklyWindowMinutes, resetsAt: nil),
            Self.window(minutes: Self.weeklyWindowMinutes, resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60)),
            Self.window(minutes: Self.weeklyWindowMinutes, resetsAt: now.addingTimeInterval(8 * 24 * 60 * 60)),
            Self.window(minutes: Self.monthlyWindowSentinelMinutes, resetsAt: nil),
            Self.window(
                minutes: Self.monthlyWindowSentinelMinutes,
                resetsAt: now.addingTimeInterval(20 * 24 * 60 * 60)),
            Self.window(minutes: 0, resetsAt: now.addingTimeInterval(60)),
            Self.window(minutes: Self.weeklyWindowMinutes, resetsAt: now.addingTimeInterval(-60)),
        ]

        for provider in UsageProvider.allCases {
            let capability = ProviderDescriptorRegistry.descriptor(for: provider).pace
            for window in fixtures {
                let actualResetWindowPace = capability.supportsResetWindowPace(window: window, now: now)
                let legacyResetWindowPace = Self.legacySupportsResetWindowPace(
                    provider: provider,
                    window: window,
                    now: now)
                #expect(
                    actualResetWindowPace == legacyResetWindowPace,
                    "Reset-window pace changed for \(provider.rawValue), window=\(String(describing: window)).")

                let actualMonthlyInference = capability.usesInferredMonthlyDuration(window: window)
                let legacyMonthlyInference = Self.legacyUsesInferredMonthlyDuration(
                    provider: provider,
                    window: window)
                #expect(
                    actualMonthlyInference == legacyMonthlyInference,
                    "Monthly inference changed for \(provider.rawValue), window=\(String(describing: window)).")
            }
        }
    }

    private static func window(minutes: Int?, resetsAt: Date?) -> RateWindow {
        RateWindow(
            usedPercent: 50,
            windowMinutes: minutes,
            resetsAt: resetsAt,
            resetDescription: nil)
    }

    /// Snapshot of the switches removed from UsageMenuCardView.Model.
    private static func legacySupportsResetWindowPace(
        provider: UsageProvider,
        window: RateWindow,
        now: Date) -> Bool
    {
        switch provider {
        case .copilot:
            return window.resetsAt != nil
        case .cursor:
            return window.windowMinutes != nil
        case .grok:
            guard GrokProviderDescriptor.primaryLabel(window: window, now: now) == "Weekly",
                  let resetsAt = window.resetsAt
            else { return false }
            let windowMinutes = window.windowMinutes ?? self.weeklyWindowMinutes
            let timeUntilReset = resetsAt.timeIntervalSince(now)
            return windowMinutes > 0
                && timeUntilReset > 0
                && timeUntilReset <= TimeInterval(windowMinutes) * 60
        case .alibaba, .alibabatokenplan, .doubao, .opencodego:
            return window.windowMinutes == self.monthlyWindowSentinelMinutes
        default:
            return false
        }
    }

    private static func legacyUsesInferredMonthlyDuration(
        provider: UsageProvider,
        window: RateWindow) -> Bool
    {
        switch provider {
        case .copilot:
            window.windowMinutes == nil
        case .alibaba, .alibabatokenplan, .doubao, .opencodego:
            window.windowMinutes == self.monthlyWindowSentinelMinutes
        default:
            false
        }
    }
}
