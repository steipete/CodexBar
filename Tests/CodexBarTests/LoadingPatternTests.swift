import Foundation
import Testing
@testable import CodexBar

struct LoadingPatternTests {
    @Test
    func `values stay within bounds`() {
        for pattern in LoadingPattern.allCases {
            for phase in stride(from: 0.0, through: Double.pi * 2, by: Double.pi / 6) {
                let v = pattern.value(phase: phase)
                #expect(v >= 0 && v <= 100, "pattern \(pattern) out of bounds at phase \(phase)")
            }
        }
    }

    @Test
    func `knight rider ping pongs`() {
        let pattern = LoadingPattern.knightRider
        let mid = pattern.value(phase: 0) // sin 0 = 0 => 50
        let min = pattern.value(phase: -Double.pi / 2) // sin -pi/2 = -1 => 0
        let max = pattern.value(phase: Double.pi / 2) // sin pi/2 = 1 => 100
        #expect(min <= mid && mid <= max)
        #expect(min == 0)
        #expect(max == 100)
    }

    @Test
    func `secondary offset differs`() {
        let pattern = LoadingPattern.cylon
        let primary = pattern.value(phase: 0)
        let secondary = pattern.value(phase: pattern.secondaryOffset)
        #expect(primary != secondary, "secondary should be offset from primary")
    }
}
