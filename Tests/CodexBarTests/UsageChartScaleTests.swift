import CodexBarCore
import Testing

struct UsageChartScaleTests {
    @Test
    func `sub dollar maximum fills the chart`() {
        let scale = UsageChartScale(values: [0.10, 0.25, 0.50])

        #expect(scale.maximum == 0.50)
        #expect(scale.fraction(for: 0.50) == 1)
        #expect(scale.fraction(for: 0.25) == 0.5)
    }

    @Test
    func `scale ignores invalid and nonpositive values`() {
        let scale = UsageChartScale(values: [.nan, .infinity, -10, 0, 4])

        #expect(scale.maximum == 4)
        #expect(scale.fraction(for: .nan) == 0)
        #expect(scale.fraction(for: -1) == 0)
        #expect(scale.fraction(for: 8) == 1)
    }
}
