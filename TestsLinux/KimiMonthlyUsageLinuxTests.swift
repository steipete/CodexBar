#if os(Linux) || CODEXBAR_KIMI_CORE_TESTS
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
    }

    @Test(arguments: [0.0, 99.0, 100.0], [false, true])
    func `only known exhausted monthly pools override reset sessions`(used: Double, known: Bool) {
        let session = Self.window(used: 0, minutes: 300)
        let monthly = Self.window(used: used, minutes: ProviderPaceCapability.monthlyWindowSentinelMinutes)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: session,
            extraRateWindows: [.init(
                id: "kimi-monthly", title: "Total usage", window: monthly, usageKnown: known)],
            updatedAt: Self.now)
        let result = KimiProviderDescriptor.descriptor.presentation.menuBarWindow(context: .init(
            metric: .automatic,
            snapshot: snapshot,
            supportsAverage: false,
            prioritizesExhaustedQuotas: false,
            now: Self.now))
        guard case let .resolved(window) = result else {
            Issue.record("Automatic Kimi selection must resolve")
            return
        }
        #expect(window == (known && used == 100 ? monthly : session))
    }

    @Test(arguments: ["2026-10-06T13:23:46Z", "2026-10-06T13:24:00Z"])
    func `matching counters reconcile while monthly usage remains in CLI text`(reset: String) throws {
        let snapshot = try KimiUsageFetcher.parseCodeAPIUsage(from: Data("""
        {"limits": [{"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
          "detail": {"limit": "100", "used": "100", "resetTime": "2026-10-06T13:23:46.915474Z"}}],
         "usages": {"limit_5h": {"used_ratio": 0, "reset_time": "\(reset)"},
          "limit_month_total": {"used_ratio": 0.5531, "reset_time": "2026-10-22T14:26:29Z"}}}
        """.utf8), now: Self.now).toUsageSnapshot()
        let matching = reset == "2026-10-06T13:23:46Z"
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary?.usedPercent == (matching ? 100 : 0))
        let monthly = try #require(snapshot.extraRateWindows?.first)
        #expect(abs(monthly.window.usedPercent - 55.31) < 0.00001)
        let output = CLIRenderer.renderText(
            provider: .kimi,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(header: "Kimi Code", status: nil, useColor: false, resetStyle: .countdown),
            now: Self.now)
        #expect(output.contains(matching ? "5-hour usage: 0% left" : "5-hour usage: 100% left"))
        #expect(output.contains("Total usage: 45% left"))
        #expect(!output.contains("7-day usage:"))
    }

    private static func window(used: Double, minutes: Int) -> RateWindow {
        RateWindow(usedPercent: used, windowMinutes: minutes, resetsAt: nil, resetDescription: nil)
    }
}
#endif
