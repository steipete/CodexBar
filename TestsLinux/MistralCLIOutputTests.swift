import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct MistralCLIOutputTests {
    @Test
    func `Monthly Plan reaches CLI text output with its amount detail`() {
        let reset = Date(timeIntervalSince1970: 1_790_812_800)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 75,
                windowMinutes: nil,
                resetsAt: reset,
                resetDescription: "€19.17 / €25.50 · €6.33 left"),
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "mistral-monthly-plan",
                    title: "Monthly Plan",
                    window: RateWindow(
                        usedPercent: 13,
                        windowMinutes: nil,
                        resetsAt: reset,
                        resetDescription: "€34.07 / €255.00 · €220.93 left")),
                NamedRateWindow(
                    id: "unrelated-window",
                    title: "Unrelated",
                    window: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil)),
            ],
            updatedAt: Date(timeIntervalSince1970: 1))

        let output = CLIRenderer.renderText(
            provider: .mistral,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "Mistral",
                status: nil,
                useColor: false,
                resetStyle: .absolute))

        #expect(output.contains("Included API: 25% left"))
        #expect(output.contains("Monthly Plan: 87% left"))
        #expect(output.contains("€34.07 / €255.00 · €220.93 left"))
        #expect(!output.contains("Unrelated"))
    }
}
