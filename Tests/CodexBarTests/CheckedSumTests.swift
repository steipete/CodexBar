import Testing
@testable import CodexBarCore

struct CheckedSumTests {
    @Test(arguments: [
        ([], 0),
        ([0], 0),
        ([10, 20], 30),
        ([Int.max], Int.max),
        ([Int.min], Int.min),
        ([Int.max, 1], nil),
        ([Int.min, -1], nil),
        ([Int.max, 1, -1], nil),
        ([Int.max, -1], Int.max - 1),
    ] as [([Int], Int?)])
    func `integer totals preserve bounds and never recover after overflow`(values: [Int], expected: Int?) {
        #expect(CheckedSum.integers(values) == expected)
    }
}
