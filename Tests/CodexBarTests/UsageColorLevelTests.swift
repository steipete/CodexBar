import AppKit
import Testing
@testable import CodexBar

struct UsageColorLevelTests {
    private func redComponent(_ color: NSColor?) -> CGFloat? {
        guard let resolved = color?.usingColorSpace(.sRGB) else { return nil }
        var r: CGFloat = 0
        resolved.getRed(&r, green: nil, blue: nil, alpha: nil)
        return r
    }

    @Test
    func nilUsageReturnsNoTint() {
        #expect(UsageColorLevel.tintColor(for: nil) == nil)
    }

    @Test
    func highUsageIsSystemRed() {
        #expect(UsageColorLevel.tintColor(for: 90) == .systemRed)
        #expect(UsageColorLevel.tintColor(for: 100) == .systemRed)
        // Values above 100 are clamped and still red.
        #expect(UsageColorLevel.tintColor(for: 250) == .systemRed)
    }

    @Test
    func rednessIncreasesWithUsage() throws {
        let low = try #require(self.redComponent(UsageColorLevel.tintColor(for: 10)))
        let mid = try #require(self.redComponent(UsageColorLevel.tintColor(for: 80)))
        let high = try #require(self.redComponent(UsageColorLevel.tintColor(for: 95)))
        #expect(low < mid)
        #expect(mid <= high)
    }

    @Test
    func lowUsageIsGreenDominant() throws {
        let color = try #require(UsageColorLevel.tintColor(for: 0)?.usingColorSpace(.sRGB))
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: nil)
        #expect(g > r)
        #expect(g > b)
    }
}
