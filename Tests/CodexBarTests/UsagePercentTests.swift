import Testing
@testable import CodexBarCore

struct UsagePercentTests {
    @Test
    func `display normalization preserves boundaries and small percentages`() {
        #expect(UsagePercent(raw: 0).displayClamped == 0)
        #expect(UsagePercent(raw: 0.25).displayClamped == 0.25)
        #expect(UsagePercent(raw: 100).displayClamped == 100)
    }

    @Test
    func `display normalization clamps overage while preserving the raw percentage`() {
        let percent = UsagePercent(used: 150, limit: 100)

        #expect(percent.raw == 150)
        #expect(percent.displayClamped == 100)
    }

    @Test
    func `display normalization guards negative usage`() {
        let percent = UsagePercent(used: -1, limit: 100)

        #expect(percent.raw == -1)
        #expect(percent.displayClamped == 0)
    }
}
