#if os(Linux)
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct KimiMonthlyUsageLinuxTests {
    private static let now = Date(timeIntervalSince1970: 1_791_284_400)

    @Test
    func `exhausted monthly pool wins automatic selection without changing explicit choices`() {
        let session = Self.window(used: 0, minutes: 300)
        let monthly = Self.window(used: 100, minutes: ProviderPaceCapability.monthlyWindowSentinelMinutes)
        let snapshot = UsageSnapshot(
            primary: Self.window(used: 0, minutes: 10080),
            secondary: session,
            extraRateWindows: [.init(id: "kimi-monthly", title: "Total usage", window: monthly)],
            updatedAt: Self.now)
        let presentation = KimiProviderDescriptor.descriptor.presentation
        for metric in [ProviderMenuBarMetric.automatic, .primary, .secondary] {
            let result = presentation.menuBarWindow(context: .init(
                metric: metric,
                snapshot: snapshot,
                supportsAverage: false,
                prioritizesExhaustedQuotas: false,
                now: Self.now))
            switch result {
            case let .resolved(window):
                #expect(metric == .automatic)
                #expect(window == monthly)
            case .unhandled:
                #expect(metric != .automatic)
            }
        }
        #expect(presentation.menuCard.blockingQuota?.windowID == "kimi-monthly")
        #expect(presentation.menuCard.blockingQuota?.message == "Blocked by monthly limit")
        #expect(RateWindow.bindingQuotaProjection(
            primary: session, bindingLanes: [monthly], now: Self.now)?.usedPercent == 100)
        #expect(snapshot.secondary?.usedPercent == 0)
        let output = CLIRenderer.renderText(
            provider: .kimi,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(header: "Kimi Code", status: nil, useColor: false, resetStyle: .countdown),
            now: Self.now)
        #expect(output.contains("Total usage: 0% left"))
        #expect(output.contains("5-hour usage: 100% left"))
    }

    private static func window(used: Double, minutes: Int) -> RateWindow {
        RateWindow(usedPercent: used, windowMinutes: minutes, resetsAt: nil, resetDescription: nil)
    }
}
#endif
