import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CodexMenuBarMetricAverageTests {
    @Test
    func `average window is nil for empty inputs`() {
        let window = CodexMenuBarMetricAverage.averageWindow(active: nil, imported: [])

        #expect(window == nil)
    }

    @Test
    func `average window keeps active only value`() throws {
        let active = Self.window(usedPercent: 37)

        let window = try #require(CodexMenuBarMetricAverage.averageWindow(active: active, imported: []))

        #expect(window.usedPercent == 37)
        #expect(window.windowMinutes == 300)
    }

    @Test
    func `average window averages imported only values`() throws {
        let window = try #require(CodexMenuBarMetricAverage.averageWindow(
            active: nil,
            imported: [
                Self.window(usedPercent: 20),
                Self.window(usedPercent: 80),
            ]))

        #expect(window.usedPercent == 50)
    }

    @Test
    func `average window averages active and imported values`() throws {
        let window = try #require(CodexMenuBarMetricAverage.averageWindow(
            active: Self.window(usedPercent: 10),
            imported: [
                Self.window(usedPercent: 40),
                Self.window(usedPercent: 70),
            ]))

        #expect(window.usedPercent == 40)
    }

    private static func window(usedPercent: Double) -> RateWindow {
        RateWindow(usedPercent: usedPercent, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
    }
}
